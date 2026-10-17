#!/usr/bin/env bash
# 起源引擎（Source Engine）32 位游戏在 ARM + box86 上的通用启动脚本
#
# 解决的问题
#   1. 引擎是按 "portal2/bin/client.so" 这类路径加载游戏模块的，而新版 Steam
#      把 .so 放进了 "<mod>/bin/linux32/"，不补 LD_LIBRARY_PATH 就会
#      "dlopen ... failed error=2"，随后引擎空转/闪退；
#   2. 手动启动容易漏掉 bin 与 bin/linux32 两级目录；
#   3. RK3588 这类大小核机器需要绑大核，否则延迟抖动明显。
#
# 用法
#   ./play_source.sh "/home/momo/.local/share/Steam/steamapps/common/Portal 2"
#   ./play_source.sh "<游戏目录>" -game portal2 +map sp_a1_intro1 +cl_showfps 2
#   DRY_RUN=1 ./play_source.sh "<游戏目录>"        # 只打印命令
#   CPUS=6-7 ./play_source.sh "<游戏目录>"          # 指定绑核
#
# 环境变量
#   CPUS            taskset 核心列表，默认 4-7；置空则不绑核
#   BOX86_DYNAREC   0 = 强制解释器（部分游戏关卡内有未实现指令时更稳）
#   BOX86_LOG       1 = 打开 box86 日志
#   BOX86_BIN       box86 路径，默认 box86
set -euo pipefail

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

[[ $# -ge 1 ]] || usage
GAME_DIR=${1%/}
shift || true

[[ -d "$GAME_DIR" ]] || { echo "游戏目录不存在：$GAME_DIR" >&2; exit 1; }

BOX86_BIN=${BOX86_BIN:-box86}
command -v "$BOX86_BIN" >/dev/null 2>&1 || { echo "找不到 box86：$BOX86_BIN" >&2; exit 1; }

# ---------------------------------------------------------------- 找 mod 目录
# 优先用启动器名推断（portal2_linux -> portal2），否则取最浅/最短的 gameinfo.txt 目录
MOD_DIR=""
LAUNCHER_BASE=""
for f in "$GAME_DIR"/*_linux "$GAME_DIR"/*_linux32; do
    [[ -f "$f" ]] || continue
    LAUNCHER_BASE=$(basename "$f")
    LAUNCHER_BASE=${LAUNCHER_BASE%_linux32}
    LAUNCHER_BASE=${LAUNCHER_BASE%_linux}
    break
done
if [[ -n "$LAUNCHER_BASE" && -f "$GAME_DIR/$LAUNCHER_BASE/gameinfo.txt" ]]; then
    MOD_DIR="$GAME_DIR/$LAUNCHER_BASE"
else
    while IFS= read -r info; do
        MOD_DIR=$(dirname "$info")
        break
    done < <(find "$GAME_DIR" -maxdepth 2 -name gameinfo.txt 2>/dev/null | awk '{ print length, $0 }' | sort -n | cut -d' ' -f2-)
fi

if [[ -z "$MOD_DIR" ]]; then
    echo "警告：没找到 gameinfo.txt，按目录名猜测 mod 目录" >&2
    MOD_DIR="$GAME_DIR/$(basename "$GAME_DIR" | tr '[:upper:] ' '[:lower:]_')"
fi

# ---------------------------------------------------------------- 找启动器
LAUNCHER=""
while IFS= read -r f; do
    # 顶层 *_linux / *_linux32 且是可执行 ELF
    if head -c 4 "$f" 2>/dev/null | grep -q $'\x7fELF'; then
        LAUNCHER="$f"
        break
    fi
done < <(find "$GAME_DIR" -maxdepth 1 -type f \( -name '*_linux' -o -name '*_linux32' \) -perm -u+x 2>/dev/null | sort)

if [[ -z "$LAUNCHER" ]]; then
    echo "没找到引擎启动器（*_linux / *_linux32），请把可执行文件路径作为第二个参数传入" >&2
    echo "已识别 mod 目录：$MOD_DIR" >&2
    exit 1
fi

# ------------------------------------------------------- 拼 LD_LIBRARY_PATH
# 顺序很重要：游戏自带库 > 引擎 bin > 系统
LIBS=()
for d in "$MOD_DIR/bin/linux32" "$GAME_DIR/bin/linux32" "$MOD_DIR/bin" "$GAME_DIR/bin"; do
    [[ -d "$d" ]] && LIBS+=("$d")
done
LIB_PATH=$(IFS=:; echo "${LIBS[*]:-}")

echo "游戏目录 : $GAME_DIR"
echo "mod 目录 : $MOD_DIR"
echo "启动器   : $LAUNCHER"
echo "库路径   : ${LIB_PATH:-<空>}"

CMD=()
[[ -n "${CPUS:-4-7}" ]] && CMD+=(taskset -c "${CPUS:-4-7}")
CMD+=("$BOX86_BIN" "$LAUNCHER")

if [[ ${DRY_RUN:-0} == "1" ]]; then
    echo
    echo "LD_LIBRARY_PATH=\"$LIB_PATH\" \\"
    printf '  %q ' "${CMD[@]}"
    printf '%q ' "$@"
    echo
    exit 0
fi

# 引擎是按相对路径找 hl2/、platform/ 等资源的，必须切到游戏根目录再执行；
# 否则 hl2_linux 会直接打印 "Failed to load the launcher" 退出。
cd "$GAME_DIR"

export LD_LIBRARY_PATH="$LIB_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
[[ -n "${BOX86_LOG:-}" ]] && export BOX86_LOG
[[ -n "${BOX86_DYNAREC:-}" ]] && export BOX86_DYNAREC

echo
exec "${CMD[@]}" "$@"
