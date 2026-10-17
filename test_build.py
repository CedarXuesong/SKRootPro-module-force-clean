import base64
import gzip
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import build


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.helper = self.root / 'helper'
        fake = bytearray(128)
        fake[:6] = b'\x7fELF\x02\x01'
        fake[18:20] = (183).to_bytes(2, 'little')
        self.helper.write_bytes(fake)

    def tearDown(self):
        self.temporary.cleanup()

    def test_single_file_payload_roundtrip(self):
        output = self.root / 'release.sh'
        build.pack(self.helper, output)
        stub, encoded = output.read_bytes().split(b'\n__SKP_PAYLOAD_BELOW__\n', 1)
        payload = base64.decodebytes(encoded)
        self.assertIn(hashlib.sha256(payload).hexdigest().encode(), stub)
        with tarfile.open(fileobj=io.BytesIO(gzip.decompress(payload))) as archive:
            self.assertEqual(archive.getnames(), ['main.sh', 'skp_module_query'])
            self.assertEqual(archive.extractfile('skp_module_query').read(), self.helper.read_bytes())
            self.assertIn('默认必须隐藏输入'.encode(), archive.extractfile('main.sh').read())
            for member in archive.getmembers():
                self.assertEqual((member.mode, member.uid, member.gid, member.mtime), (0o700, 0, 0, 0))

    def test_identical_inputs_produce_identical_sh(self):
        first, second = self.root / 'one.sh', self.root / 'two.sh'
        build.pack(self.helper, first)
        build.pack(self.helper, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_non_arm64_helper_rejected(self):
        self.helper.write_bytes(b'not an ELF')
        with self.assertRaises(SystemExit):
            build.pack(self.helper, self.root / 'release.sh')

    def test_generic_sources_have_no_device_module_special_case(self):
        source = (build.ROOT / 'module_force_clean.template.sh').read_text(encoding='utf8')
        for removed in ('--dfm', 'dfm_sf_'):
            self.assertNotIn(removed, source)
        self.assertNotRegex(source, r'/data/[A-Za-z0-9]{17}/modules')
        self.assertIn('while ! authenticate', source)


if __name__ == '__main__':
    unittest.main()
