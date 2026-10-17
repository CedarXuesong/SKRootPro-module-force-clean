#!/system/bin/sh
# SKRoot Pro module cleaner. The distribution embeds this script and its SDK helper.
set -eu
umask 077
VERSION=1.0.0
cyan= green= yellow= red= bold= reset=
color_mode=auto
module_root= requested_id= legacy_id= apply=0 reboot_after=0
helper=${SKP_HELPER:-$(dirname "$0")/skp_module_query}
die() { printf '%s错误：%s%s\n' "$red" "$*" "$reset" >&2; exit 1; }
info() { printf '%s%s%s\n' "$cyan" "$*" "$reset"; }
warn() { printf '%s%s%s\n' "$yellow" "$*" "$reset"; }
ok() { printf '%s%s%s\n' "$green" "$*" "$reset"; }
ask() { printf '%s%s%s' "$cyan" "$*" "$reset"; }
valid_id() { case "$1" in ''|.|..|*[!A-Za-z0-9_.-]*) return 1 ;; esac; }
valid_root() {
    case "$1" in /data/*/modules) ;; *) return 1 ;; esac
    component=${1#/data/}; component=${component%/modules}
    valid_id "$component" && [ -d "$1" ] && [ "$(readlink -f "$1")" = "$1" ]
}
usage() {
    cat <<'EOF'
SKP模块强制清理 ❤ Github/CedarXuesong
用法：su -c 'sh SKRootPro-module-force-clean.sh'
可选参数：
  --id ID            认证后直接选择 SDK 列表中的模块，默认预览
  --apply            认证后备份并清理 --id 指定模块
  --reboot           清理成功后重启，必须配合 --apply
  --module-root DIR  SDK 布局变化时提供 /data/NAME/modules 路径提示
  --legacy-id ID     显式追加 /data/adb 下的兼容目录 ID
  --color            强制彩色
  --no-color         关闭彩色
  --version          显示版本
默认必须隐藏输入当前设备的 SKP 密钥。任何模块清理前都会备份。
EOF
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --id|--legacy-id|--module-root)
            [ "$#" -ge 2 ] || die "$1 缺少参数"
            case "$1" in
                --id) valid_id "$2" || die '无效模块 ID'; requested_id=$2 ;;
                --legacy-id) valid_id "$2" || die '无效兼容 ID'; legacy_id=$2 ;;
                --module-root) module_root=${2%/}; valid_root "$module_root" || die '目录不存在、格式不符或包含符号链接' ;;
            esac
            shift 2 ;;
        --apply) apply=1; shift ;;
        --reboot) reboot_after=1; shift ;;
        --color) color_mode=always; shift ;;
        --no-color) color_mode=never; shift ;;
        --version) printf '%s\n' "$VERSION"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done
if [ "$color_mode" = always ] || { [ "$color_mode" = auto ] && [ -t 1 ] && [ "${TERM:-}" != dumb ]; }; then
    cyan=$(printf '\033[36m'); green=$(printf '\033[32m'); yellow=$(printf '\033[33m')
    red=$(printf '\033[31m'); bold=$(printf '\033[1m'); reset=$(printf '\033[0m')
fi
[ "$(id -u)" = 0 ] || die "请通过 su 运行本脚本"
[ -x "$helper" ] || die "配套 SDK 查询程序不可用，请使用发布的内嵌版 SH"
[ "$reboot_after" = 0 ] || [ "$apply" = 1 ] || die '--reboot 必须配合 --apply'
[ "$apply" = 0 ] || [ -n "$requested_id" ] || die '--apply 必须指定 --id'
for cmd in readlink awk tar sha256sum; do command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"; done

banner() {
    printf '\n%s%s┌─────────────────────────────────────────┐\n' "$bold" "$cyan"
    printf '│  SKP模块强制清理 ❤ Github/CedarXuesong  │\n'
    printf '└─────────────────────────────────────────┘%s\n' "$reset"
    printf '  版本：%s  ·  密钥认证 / 自动定位 / 备份清理\n' "$VERSION"
}
authenticate() {
    set -- --prompt
    [ -z "$module_root" ] || set -- "$@" --root "$module_root"
    info '请输入当前设备的 SKP 密钥；输入隐藏，仅用于本次查询，不保存。'
    if ! sdk_output=$("$helper" "$@"); then warn '认证查询失败或已取消。'; return 1; fi
    if ! printf '%s\n' "$sdk_output" | awk -F '|' '$1=="SKP1" && $2=="DONE" && $3 ~ /^[0-9]+$/ {found=1} END {exit !found}'; then
        warn 'SDK 响应不完整，已忽略。'; return 1
    fi
    records=$(printf '%s\n' "$sdk_output" | awk -F '|' '$1=="SKP1" && $2=="MODULE" && NF==7 {print $3 "|" $4 "|" $5 "|" $6 "|" $7}')
    sdk_output=
    selected_id= selected_root= selected_name= selected_desc= selected_state=
    count=$(printf '%s\n' "$records" | awk 'NF {n++} END {print n+0}')
    ok "认证成功，已查询 $count 个模块。"
}
show_modules() {
    [ -n "$records" ] || { warn 'SDK 列表为空。'; return 0; }
    printf '%s\n' "$records" | awk -F '|' '{printf "\n  %d. 名称：%s\n     描述：%s\n     状态：%s\n     ID：%s\n     目录：%s\n", NR, ($3?$3:$2), ($4?$4:"未提供模块描述"), $5, $2, ($1?$1:"未定位")}'
}
choose_record() {
    selected_root=${record%%'|'*}; rest=${record#*'|'}
    selected_id=${rest%%'|'*}; rest=${rest#*'|'}
    selected_name=${rest%%'|'*}; rest=${rest#*'|'}
    selected_desc=${rest%%'|'*}; selected_state=${rest#*'|'}
    valid_id "$selected_id" || die 'SDK 返回的模块 ID 无效'
    ok "已选择：${selected_name:-$selected_id}"
}
validate_target() {
    target=$1
    case "$target" in
        "$selected_root/$selected_id") [ -n "$selected_root" ] || die '模块目录未定位' ;;
        /data/adb/modules/"$selected_id"|/data/adb/modules_update/"$selected_id") ;;
        /data/adb/modules/"$legacy_id"|/data/adb/modules_update/"$legacy_id") [ -n "$legacy_id" ] || die '兼容 ID 不能为空' ;;
        *) die "路径不在清理范围内：$target" ;;
    esac
    [ ! -L "$target" ] && [ "$(readlink -f "$target")" = "$target" ] || die "拒绝符号链接或非规范路径：$target"
}
check_mounts() {
    if awk -v p="$1" '$2==p || index($2,p "/")==1 {found=1} END {exit !found}' /proc/mounts; then
        die "路径存在挂载点，请先处理挂载：$1"
    fi
}
add_target() {
    [ -e "$1" ] || [ -L "$1" ] || return 0
    validate_target "$1"
    case "
$paths
" in *"
$1
"*) return 0 ;; esac
    paths="${paths}${1}
"
}
plan_cleanup() {
    paths=
    [ -n "$selected_id" ] || { warn '请先选择模块。'; return 1; }
    if [ -n "$module_root" ] && valid_root "$module_root" && [ -d "$module_root/$selected_id" ]; then
        selected_root=$module_root
    fi
    if [ -z "$selected_root" ] || ! valid_root "$selected_root"; then
        warn '实际目录未定位，请设置目录提示后重新认证查询。'; return 1
    fi
    add_target "$selected_root/$selected_id"
    add_target "/data/adb/modules/$selected_id"
    add_target "/data/adb/modules_update/$selected_id"
    if [ -n "$legacy_id" ]; then
        add_target "/data/adb/modules/$legacy_id"
        add_target "/data/adb/modules_update/$legacy_id"
    fi
    [ -n "$paths" ] || { warn '模块目录已不存在，无需清理。'; return 1; }
    info "清理预览：${selected_name:-$selected_id}"
    printf '%s' "$paths"
    warn '只清理以上路径；已加载的内核 Hook 需要重启清除。'
}
perform_cleanup() {
    backup="/data/local/tmp/skp-module-backup-$(date +%Y%m%d_%H%M%S)-$$"
    [ "$(readlink -f /data/local/tmp)" = /data/local/tmp ] || die '备份父目录不是规范路径'
    mkdir -m 700 "$backup" || die '无法创建备份目录'
    [ "$(readlink -f "$backup")" = "$backup" ] || die '备份目录不符合要求'
    printf '%s' "$paths" > "$backup/paths.txt"
    set --
    while IFS= read -r path; do
        validate_target "$path"; check_mounts "$path"
        set -- "$@" "${path#/}"
    done < "$backup/paths.txt"
    tar -czf "$backup/backup.tar.gz" -C / "$@" || die '备份失败，尚未删除目标'
    tar -tzf "$backup/backup.tar.gz" > "$backup/archive-list.txt" || die '备份无法读取，尚未删除目标'
    (cd "$backup" && sha256sum backup.tar.gz > SHA256SUMS && sha256sum -c SHA256SUMS) || die '备份校验失败'
    info "备份目录：$backup"
    while IFS= read -r path; do
        validate_target "$path"; check_mounts "$path"
    done < "$backup/paths.txt"
    while IFS= read -r path; do
        validate_target "$path"; check_mounts "$path"
        rm -rf -- "$path" || die "删除失败：$path；备份：$backup"
        [ ! -e "$path" ] && [ ! -L "$path" ] || die "目标仍然存在：$path"
        printf '已删除：%s\n' "$path" >> "$backup/result.txt"
    done < "$backup/paths.txt"
    while IFS= read -r path; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || die "后台进程重新创建了路径：$path；备份：$backup"
    done < "$backup/paths.txt"
    ok "清理完成。备份与记录：$backup"
    warn '请重启清除已加载的代码或内核 Hook。'
    if [ "$reboot_after" = 1 ]; then sync; reboot; fi
}

banner
records= selected_id= selected_root= selected_name= selected_desc= selected_state=
while ! authenticate; do
    ask '输入 1 重新输入密钥，其他输入退出：'
    IFS= read -r retry || exit 1
    [ "$retry" = 1 ] || exit 1
done
if [ -n "$requested_id" ]; then
    record=$(printf '%s\n' "$records" | awk -F '|' -v id="$requested_id" '$2==id {print; exit}')
    [ -n "$record" ] || die '指定模块不在 SDK 已安装列表中'
    choose_record
    plan_cleanup || exit 1
    [ "$apply" = 0 ] || perform_cleanup
    exit 0
fi

while :; do
    banner
    printf '  当前模块：%s\n' "${selected_name:-尚未选择}"
    printf '\n  %s1%s  查看并选择模块\n  %s2%s  重新输入密钥 / 刷新模块列表\n' "$cyan" "$reset" "$cyan" "$reset"
    printf '  %s3%s  设置模块目录提示\n  %s4%s  预览清理范围\n' "$cyan" "$reset" "$yellow" "$reset"
    printf '  %s5%s  备份并强制清理\n  %s6%s  备份、清理并重启\n  %s0%s  退出\n\n' "$red" "$reset" "$red" "$reset" "$cyan" "$reset"
    ask '请输入选项 [0-6]：'
    IFS= read -r choice || { printf '\n'; exit 0; }
    case "$choice" in
        0) ok '已退出。'; exit 0 ;;
        1)
            show_modules
            [ -n "$records" ] || continue
            ask '请输入模块序号（0 返回）：'
            IFS= read -r number || exit 0
            case "$number" in ''|*[!0-9]*) warn '请输入有效序号。'; continue ;; 0) continue ;; esac
            record=$(printf '%s\n' "$records" | awk -v n="$number" 'NR==n {print; exit}')
            [ -n "$record" ] || { warn '序号超出范围。'; continue; }
            choose_record ;;
        2) authenticate || warn '查询未成功，原列表和选择保持不变。' ;;
        3)
            ask '输入 /data/NAME/modules（留空清除提示）：'
            IFS= read -r hint || exit 0
            hint=${hint%/}
            if [ -n "$hint" ] && ! valid_root "$hint"; then warn '目录不存在、格式不符或包含符号链接。'; continue; fi
            module_root=$hint
            info '提示已更新，可重新认证查询；当前模块也会在预览时验证该目录。' ;;
        4) plan_cleanup || : ;;
        5|6)
            plan_cleanup || continue
            warn '将备份并删除以上路径。'
            [ "$choice" != 6 ] || warn '清理成功后设备将立即重启。'
            ask '输入“删除”确认，其他输入取消：'
            IFS= read -r confirmation || exit 0
            [ "$confirmation" = 删除 ] || { info '已取消。'; continue; }
            reboot_after=0
            [ "$choice" != 6 ] || reboot_after=1
            perform_cleanup
            selected_id= selected_root= selected_name= selected_desc= selected_state=
            records=
            warn '本次列表已清空，请使用选项 2 重新认证查询。' ;;
        *) warn '请输入 0 到 6。' ;;
    esac
done
