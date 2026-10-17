#!/system/bin/sh
# Synthetic SDK transport: never accesses real SKP credentials or modules.
set -eu
template=${1:-$(dirname "$0")/module_force_clean.template.sh}
[ "$(id -u)" = 0 ] || exit 1
tag=$(date +%Y%m%d_%H%M%S)_$$
base=/data/skp_cleaner_test_$tag
module_id=skp_fixture_$tag
[ ! -e "$base" ] || exit 1
mkdir -p "$base/modules/$module_id" "$base/modules/keep"
[ "$(readlink -f "$base")" = "$base" ] || exit 1
printf 'fixture\n' > "$base/modules/$module_id/payload"
printf 'keep\n' > "$base/modules/keep/payload"
cat > "$base/mock_query" <<EOF
#!/system/bin/sh
printf '%s\n' 'SKP1|MODULE|$base/modules|$module_id|中文测试模块|测试描述-A|运行中' 'SKP1|DONE|1'
EOF
chmod 700 "$base/mock_query"
run() { SKP_HELPER="$base/mock_query" sh "$template" --no-color "$@"; }

preview=$(run --id "$module_id")
[ -f "$base/modules/$module_id/payload" ]
case "$preview" in *"清理预览：中文测试模块"*) ;; *) exit 1 ;; esac
echo 'PASS: authenticated preview preserves target'
menu=$(printf '1\n1\n5\n取消\n0\n' | run)
case "$menu" in *"名称：中文测试模块"*"描述：测试描述-A"*"已取消。"*) ;; *) echo "$menu"; exit 1 ;; esac
[ -f "$base/modules/$module_id/payload" ]
echo 'PASS: generic menu metadata, selection and cancel'
if run --id ../keep --apply; then exit 1; fi
if run --id other_module --apply; then exit 1; fi
echo 'PASS: traversal and ID outside authenticated list rejected'
mv "$base/modules/$module_id" "$base/modules/saved_fixture"
ln -s "$base/modules/keep" "$base/modules/$module_id"
if run --id "$module_id" --apply; then exit 1; fi
[ -f "$base/modules/keep/payload" ]
rm "$base/modules/$module_id"
mv "$base/modules/saved_fixture" "$base/modules/$module_id"
echo 'PASS: symbolic-link target rejected'
result=$(run --id "$module_id" --apply)
printf '%s\n' "$result"
[ ! -e "$base/modules/$module_id" ]
[ -f "$base/modules/keep/payload" ]
backup=$(printf '%s\n' "$result" | sed -n 's/^备份目录：//p')
[ -n "$backup" ]
(cd "$backup" && sha256sum -c SHA256SUMS)
mkdir "$backup/restore-test"
tar -xzf "$backup/backup.tar.gz" -C "$backup/restore-test"
[ "$(cat "$backup/restore-test/${base#/}/modules/$module_id/payload")" = fixture ]
echo 'PASS: exact deletion, sibling preserved, backup restores original payload'
if run --id "$module_id" --apply; then exit 1; fi
echo 'PASS: repeated deletion performs no further mutation'
rm "$base/mock_query" "$base/modules/keep/payload"
rmdir "$base/modules/keep" "$base/modules" "$base"
echo "ALL TESTS PASSED; synthetic backup retained: $backup"
