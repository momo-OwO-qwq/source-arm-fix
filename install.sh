#!/usr/bin/env bash
# install.sh —— 一键「检查 → 修补 → 自检」
#
#   ./install.sh              # 交互式，确认后修补
#   ./install.sh --yes        # 不询问
#   ./install.sh --dry-run    # 只看会做什么
#   ./install.sh --restore    # 从备份还原
#   ./install.sh --file /path/to/steamclient.so
#
# 退出码：0 成功 / 1 环境或参数问题 / 2 修补失败 / 3 自检未通过
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FIX="$SCRIPT_DIR/scripts/fix_steamclient.py"

ASSUME_YES=0
DRY_RUN=0
RESTORE=0
TARGET=""

usage() {
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --restore) RESTORE=1; shift ;;
        -f|--file) TARGET=${2:?--file 需要一个路径}; shift 2 ;;
        -h|--help) usage ;;
        *) echo "未知参数：$1" >&2; usage ;;
    esac
done

FILE_ARGS=()
[[ -n "$TARGET" ]] && FILE_ARGS=(-f "$TARGET")

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ✘\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 0. 环境
say "环境检查"
command -v python3 >/dev/null 2>&1 || die "缺少 python3"
ok "python3 $(python3 -V 2>&1 | awk '{print $2}')"
[[ -f "$FIX" ]] || die "找不到 $FIX"

if [[ -n "$TARGET" ]]; then
    SO_PATH=$(python3 - "$TARGET" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]).expanduser()
print(p if p.exists() else "MISSING")
PY
)
else
    SO_PATH=$(python3 - <<'PY'
import pathlib
for pattern in ["~/.local/share/Steam/linux32/steamclient.so",
                "~/.steam/steam/linux32/steamclient.so",
                "~/.steam/root/linux32/steamclient.so"]:
    p = pathlib.Path(pattern).expanduser()
    if p.exists():
        print(p); break
else:
    print("MISSING")
PY
)
fi
[[ "$SO_PATH" != "MISSING" ]] || die "找不到 steamclient.so，可用 --file 指定"
ok "目标文件 $SO_PATH"

command -v box86 >/dev/null 2>&1 || warn "未找到 box86（修补本身不需要它，但游戏运行需要）"

if pgrep -x steamwm 2>/dev/null; then :
elif pgrep -f steamwebhelper >/dev/null 2>&1; then
    warn "检测到 Steam 正在运行；修补对已加载的进程不生效，建议修补后重启 Steam"
fi

# ---------------------------------------------------------------- 1. 还原
if [[ $RESTORE -eq 1 ]]; then
    say "从备份还原"
    [[ $DRY_RUN -eq 1 ]] && { echo "  (dry-run) python3 $FIX --restore ${FILE_ARGS[*]}"; exit 0; }
    python3 "$FIX" --restore "${FILE_ARGS[@]}" || die "还原失败"
    ok "已还原，重启 Steam 后生效"
    exit 0
fi

# ---------------------------------------------------------------- 2. 检查
say "检查缺失符号的重定位"
python3 "$FIX" --check "${FILE_ARGS[@]}"

if python3 "$FIX" --status "${FILE_ARGS[@]}"; then
    STATUS=0
else
    STATUS=$?
fi
case $STATUS in
    0) ok "当前无需修补（已经是干净状态）"; exit 0 ;;
    3) : ;;
    4) die "映射表里的替代符号在目标文件中不存在，请检查脚本 DEFAULT_MAP" ;;
    *) die "状态检查失败（退出码 $STATUS）" ;;
esac

# ---------------------------------------------------------------- 3. 确认
if [[ $DRY_RUN -eq 1 ]]; then
    echo
    say "dry-run：将执行 python3 $FIX --apply ${FILE_ARGS[*]}"
    exit 0
fi
if [[ $ASSUME_YES -ne 1 ]]; then
    echo
    read -r -p "即将修改 $SO_PATH（会自动备份）。继续？[y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }
fi

# ---------------------------------------------------------------- 4. 修补
say "应用修补"
python3 "$FIX" --apply "${FILE_ARGS[@]}" || die "修补失败"

# ---------------------------------------------------------------- 5. 自检
say "自检"
if python3 "$FIX" --status "${FILE_ARGS[@]}"; then
    ok "重定位已全部指向替代符号"
else
    die "自检未通过：仍存在待修补项"
fi

if python3 - "$SO_PATH" <<'PY'
import struct, sys, pathlib
p = pathlib.Path(sys.argv[1])
b = p.read_bytes()
assert b[:4] == b"\x7fELF" and b[4] == 1, "ELF 头异常"
e_shoff, = struct.unpack_from("<I", b, 0x20)
e_shentsize, e_shnum, _ = struct.unpack_from("<HHH", b, 0x2E)
assert 0 < e_shoff < len(b) and e_shnum > 0, "段头异常"
print(f"  ✔ ELF 结构完整（{len(b)} 字节，{e_shnum} 个段）")
PY
then :; else die "ELF 结构自检失败"; fi

BACKUP="${SO_PATH}.bak-source-arm-fix"
[[ -f "$BACKUP" ]] && ok "备份存在：$BACKUP" || warn "未找到备份文件 ${BACKUP}（首次修补会自动生成）"

echo
say "完成"
cat <<EOF
  下一步：
    1. 若 Steam 正在运行，请重启 Steam 让新的 steamclient.so 生效；
    2. 直接启动游戏（或 ./scripts/play_source.sh "<游戏目录>"）；
    3. Steam 更新客户端后补丁会被覆盖，重跑本脚本即可。

  回滚： ./install.sh --restore
EOF
