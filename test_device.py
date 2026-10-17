"""Read-only real-device test of the single embedded SH; never deletes real modules."""
import argparse
import getpass
import hashlib
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', required=True)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--script', type=Path, required=True)
    parser.add_argument('--key-stdin', action='store_true', help='Read test key from stdin rather than getpass; never saved')
    parser.add_argument('--expected-count', type=int)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    secret = (sys.stdin.buffer.readline().strip() if args.key_stdin else getpass.getpass('SKP key (not saved): ').encode('ascii'))
    assert len(secret) == 48 and secret.isalnum(), 'Invalid key format'
    adb = [args.adb, '-s', args.serial]
    directory = '/data/local/tmp/skp-singlefile-test-' + str(time.time_ns())
    remote = directory + '/cleaner.sh'
    cases = []

    def check(name, passed):
        if not passed:
            raise AssertionError(name)
        cases.append({'name': name, 'passed': True})
        print('PASS:', name, flush=True)

    def shell(command):
        return subprocess.run(adb + ['shell', command], capture_output=True, timeout=20)

    def runtimes():
        result = shell("su -c 'ls -d /data/local/tmp/skp-force-clean-runtime-* 2>/dev/null'")
        return set(result.stdout.decode('utf8', 'replace').splitlines())

    before = runtimes()
    subprocess.run(adb + ['shell', 'mkdir ' + directory], check=True, capture_output=True)
    subprocess.run(adb + ['push', str(args.script), remote], check=True, capture_output=True)
    check('single runtime file only', shell('ls -A ' + directory).stdout.decode().strip() == 'cleaner.sh')
    process = subprocess.Popen(adb + ['shell', '-tt', "su -c 'sh " + remote + " --no-color'"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    chunks = queue.Queue()
    transcript = bytearray()

    def reader():
        while True:
            data = process.stdout.read(4096)
            chunks.put(data)
            if not data:
                return

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()

    def receive(text, start=0):
        deadline = time.monotonic() + 30
        while text.encode('utf8') not in transcript[start:]:
            wait = deadline - time.monotonic()
            if wait <= 0:
                raise AssertionError('PTY prompt timeout')
            data = chunks.get(timeout=wait)
            if not data:
                raise AssertionError('PTY exited early')
            transcript.extend(data)

    def send(data):
        start = len(transcript)
        process.stdin.write(data)
        process.stdin.flush()
        return start

    wrong = b'A' * 48 if secret != b'A' * 48 else b'B' * 48
    try:
        prompt = '请输入 SKP 密钥（隐藏输入，留空取消）：'
        receive(prompt)
        check('authentication required before menu', '请输入选项'.encode('utf8') not in transcript)
        cursor = send(wrong + b'\n')
        receive('输入 1 重新输入密钥', cursor)
        check('incorrect key never opens menu', '请输入选项'.encode('utf8') not in transcript)
        cursor = send(b'1\n')
        receive(prompt, cursor)
        cursor = send(secret + b'\n')
        receive('请输入选项 [0-6]', cursor)
        check('correct key opens generic menu', '认证成功'.encode('utf8') in transcript)
        check('keys never echoed', secret not in transcript and wrong not in transcript)
        if args.expected_count is not None:
            check('SDK module count matches', ('已查询 %d 个模块' % args.expected_count).encode('utf8') in transcript)
        cursor = send(b'1\n')
        receive('请输入模块序号', cursor)
        check('names descriptions and runtime states displayed', all(s.encode('utf8') in transcript for s in ('名称：', '描述：', '状态：', '目录：')))
        cursor = send(b'1\n')
        receive('请输入选项 [0-6]', cursor)
        cursor = send(b'4\n')
        receive('清理预览：', cursor)
        receive('请输入选项 [0-6]', cursor)
        check('directory auto-located from supplied key', '实际目录未定位'.encode('utf8') not in transcript)
        cursor = send(b'0\n')
        receive('已退出。', cursor)
        check('normal exit', process.wait(timeout=10) == 0)
        check('no secret in complete session', secret not in transcript)
        check('extracted runtime cleaned up', runtimes() <= before)
    except Exception:
        print(bytes(transcript).replace(secret, b'<redacted>').replace(wrong, b'<wrong-key>').decode('utf8', 'replace'))
        raise
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
        process.stdin.close()
        process.stdout.close()
        shell('rm -f ' + remote)
        shell('rmdir ' + directory)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({'script_sha256': hashlib.sha256(args.script.read_bytes()).hexdigest(),
                                          'cases': cases}, ensure_ascii=False, indent=2), encoding='utf8')


if __name__ == '__main__':
    main()
