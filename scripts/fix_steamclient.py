#!/usr/bin/env python3
"""box86 / 32 位 Steam 客户端兼容修复工具（起源引擎游戏通用）

背景
----
Steam 会持续更新 `~/.local/share/Steam/linux32/steamclient.so`。新版客户端会引入
新的 glibc 符号（例如 GLIBC_2.30 的 `pthread_mutex_clocklock`），而 box86 的
libc/libpthread 封装表是按版本固定编译的，缺少对应封装时会直接报：

    Error: Symbol pthread_mutex_clocklock not found.
    Error: Relocation error: cannot apply R_386_JMP_SLOT ... steamclient.so

结果：`SteamAPI_Init()` 失败 → 引擎提示 "Steam is not running" → 游戏启动约 70 秒后
崩溃退出。所有依赖 Steam API 的 32 位起源引擎游戏都会中招。

本工具的解法
------------
不去改 box86、也不去改游戏：只在 ELF 的**重定位表**里，把“缺失符号”的那条
`R_386_JUMP_SLOT` 改指向一个**已经存在、调用约定兼容**的符号。
以 `pthread_mutex_clocklock` 为例，改指 `pthread_mutex_lock`：

* cdecl 调用约定下，被调用方不关心多的那个 `clockid` 参数，栈由调用方清理；
* 返回值类型一致（int，0 或错误码）；
* 唯一语义差异：失去“超时”能力，退化为阻塞加锁。

该改动只碰 `.rel.plt` 里 4 个字节的符号索引，不动代码段、不动校验和敏感的段。

用法
----
    python3 fix_steamclient.py --check          # 只检查，不修改
    python3 fix_steamclient.py --apply          # 修补（自动备份）
    python3 fix_steamclient.py --restore        # 还原备份
    python3 fix_steamclient.py --apply -f /path/to/steamclient.so
    python3 fix_steamclient.py --list-symbols   # 列出所有 JMP_SLOT 符号，便于新增映射

Steam 每次自动更新 steamclient.so 都会覆盖补丁，更新后重跑 `--apply` 即可。
"""
from __future__ import annotations

import argparse
import shutil
import struct
import sys
from pathlib import Path

# ---------------------------------------------------------------- 符号映射表
# key   = 新版 steamclient.so 需要、但 box86 没有封装的符号
# value = 已存在且调用约定兼容的替代符号
#
# 新增规则时请确认：参数个数可以多（cdecl 下多余参数被忽略），
# 返回值类型与语义要一致或退化后仍然安全。
DEFAULT_MAP = {
    "pthread_mutex_clocklock": "pthread_mutex_lock",
}

BACKUP_SUFFIX = ".bak-source-arm-fix"
R_386_JMP_SLOT = 7
R_386_GLOB_DAT = 6
# 这些重定位类型都表示“把一个函数/数据地址写进 GOT”，可以安全改指
REDIRECTABLE = {R_386_JMP_SLOT, R_386_GLOB_DAT}

CANDIDATE_PATHS = [
    "~/.local/share/Steam/linux32/steamclient.so",
    "~/.steam/steam/linux32/steamclient.so",
    "~/.steam/root/linux32/steamclient.so",
]


class Elf32Error(RuntimeError):
    pass


class Elf32:
    """够用就好的 32 位 ELF 读取/原地修补器。"""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.blob = bytearray(path.read_bytes())
        if self.blob[:4] != b"\x7fELF":
            raise Elf32Error(f"{path} 不是 ELF 文件")
        if self.blob[4] != 1:
            raise Elf32Error(f"{path} 不是 32 位 ELF（EI_CLASS={self.blob[4]}）")
        self.sections = self._parse_sections()

    # -- 基础解析 ---------------------------------------------------------
    def _parse_sections(self) -> dict[str, tuple[int, int, int]]:
        e_shoff, = struct.unpack_from("<I", self.blob, 0x20)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", self.blob, 0x2E)
        raw = []
        for i in range(e_shnum):
            base = e_shoff + i * e_shentsize
            name_off, sh_type, _flags, sh_addr, sh_offset, sh_size = struct.unpack_from(
                "<IIIIII", self.blob, base
            )
            raw.append((name_off, sh_type, sh_addr, sh_offset, sh_size))
        shstr_off = raw[e_shstrndx][3]
        out = {}
        for name_off, sh_type, sh_addr, sh_offset, sh_size in raw:
            end = self.blob.index(b"\0", shstr_off + name_off)
            name = self.blob[shstr_off + name_off:end].decode(errors="replace")
            out[name] = (sh_addr, sh_offset, sh_size)
        return out

    def _sym_name(self, idx: int) -> str:
        _addr, dynsym_off, dynsym_size = self.sections[".dynsym"]
        _saddr, dynstr_off, _ssize = self.sections[".dynstr"]
        if idx * 16 >= dynsym_size:
            return ""
        name_off, = struct.unpack_from("<I", self.blob, dynsym_off + idx * 16)
        end = self.blob.index(b"\0", dynstr_off + name_off)
        return self.blob[dynstr_off + name_off:end].decode(errors="replace")

    def symbols(self) -> dict[str, int]:
        """{符号名: dynsym 索引}，同名只保留第一个。"""
        _a, _o, dynsym_size = self.sections[".dynsym"]
        out: dict[str, int] = {}
        for i in range(1, dynsym_size // 16):
            name = self._sym_name(i)
            if name and name not in out:
                out[name] = i
        return out

    def relocations(self):
        """遍历 .rel.plt / .rel.dyn：(文件偏移, r_offset, 符号名, 类型)。"""
        for sec in (".rel.plt", ".rel.dyn"):
            if sec not in self.sections:
                continue
            _addr, off, size = self.sections[sec]
            for i in range(size // 8):
                entry = off + i * 8
                r_offset, r_info = struct.unpack_from("<II", self.blob, entry)
                yield entry, r_offset, self._sym_name(r_info >> 8), r_info & 0xFF

    # -- 修补 -------------------------------------------------------------
    def redirect(self, src: str, dst: str) -> int:
        syms = self.symbols()
        if src not in syms:
            raise Elf32Error(f"未找到符号 {src}")
        if dst not in syms:
            raise Elf32Error(f"未找到替代符号 {dst}")
        src_idx, dst_idx = syms[src], syms[dst]
        changed = 0
        for entry, r_offset, name, rtype in list(self.relocations()):
            if name != src or rtype not in REDIRECTABLE:
                continue
            struct.pack_into("<I", self.blob, entry + 4, (dst_idx << 8) | rtype)
            print(f"  · r_offset={r_offset:#010x} type={rtype} {src}({src_idx}) -> {dst}({dst_idx})")
            changed += 1
        return changed

    def save(self) -> None:
        self.path.write_bytes(bytes(self.blob))


# ------------------------------------------------------------------ 工具函数
def find_steamclient(explicit: str | None) -> Path:
    if explicit:
        p = Path(explicit).expanduser()
        if not p.exists():
            raise SystemExit(f"找不到文件：{p}")
        return p
    for pattern in CANDIDATE_PATHS:
        p = Path(pattern).expanduser()
        if p.exists():
            return p
    raise SystemExit("没有自动找到 steamclient.so，请用 -f 指定路径")


def missing_symbols(elf: Elf32, mapping: dict[str, str]) -> list[tuple[str, str]]:
    """返回 (缺失符号, 替代符号) —— 仅当替代符号存在时才算可修。"""
    syms = elf.symbols()
    return [(src, dst) for src, dst in mapping.items() if src in syms and dst in syms]


def cmd_check(elf: Elf32, mapping: dict[str, str]) -> int:
    syms = elf.symbols()
    print(f"文件: {elf.path}")
    pending = []
    done = []
    for src, dst in mapping.items():
        if src not in syms:
            continue
        referenced = any(n == src for _e, _o, n, _t in elf.relocations())
        if referenced and dst in syms:
            pending.append((src, dst))
        elif referenced:
            pending.append((src, None))
        else:
            done.append((src, dst))
    if not pending and not done:
        print("本版本 steamclient.so 没有引用映射表内的符号，无需处理。")
        return 0
    for src, dst in pending:
        if dst:
            print(f"  [待修补] {src} -> {dst}")
        else:
            print(f"  [待修补] {src}（但替代符号 {mapping[src]} 不存在，请先补映射表）")
    for src, dst in done:
        print(f"  [已修补] {src} 已不再被直接引用（当前指向 {dst}）")
    return 0


def cmd_list(elf: Elf32) -> int:
    names = sorted({n for _e, _o, n, _t in elf.relocations() if n})
    print(f"共 {len(names)} 个被重定位引用的符号：\n")
    for n in names:
        print(" ", n)
    return 0


def cmd_apply(elf: Elf32, mapping: dict[str, str]) -> int:
    todo = missing_symbols(elf, mapping)
    if not todo:
        print("映射表中没有可修补的符号，无需改动。")
        return 0
    backup = elf.path.with_name(elf.path.name + BACKUP_SUFFIX)
    if not backup.exists():
        shutil.copy2(elf.path, backup)
        print(f"已备份 -> {backup}")
    total = 0
    print("开始修补：")
    for src, dst in todo:
        total += elf.redirect(src, dst)
    if total:
        elf.save()
        print(f"\n完成，共 {total} 处。请重新启动游戏；Steam 更新客户端后需重跑本命令。")
    else:
        print("\n没有实际改动（可能已经修补过）。")
    return 0


def cmd_restore(elf: Elf32) -> int:
    backup = elf.path.with_name(elf.path.name + BACKUP_SUFFIX)
    if not backup.exists():
        raise SystemExit(f"没有找到备份：{backup}")
    shutil.copy2(backup, elf.path)
    print(f"已从备份还原：{elf.path}")
    return 0


def cmd_status(elf: Elf32, mapping: dict[str, str]) -> int:
    """机器可读状态：0=全部已修补，3=仍有待修补项，4=映射表里的替代符号缺失。"""
    syms = elf.symbols()
    pending = 0
    for src, dst in mapping.items():
        if src not in syms:
            continue
        if not any(n == src for _e, _o, n, _t in elf.relocations()):
            continue
        if dst not in syms:
            print(f"MISSING_ALT {src} -> {dst}")
            return 4
        print(f"PENDING {src} -> {dst}")
        pending += 1
    print("OK" if pending == 0 else f"PENDING={pending}")
    return 0 if pending == 0 else 3


def main() -> int:
    ap = argparse.ArgumentParser(description="修复 box86 下 32 位 Steam 客户端缺失符号导致的启动崩溃")
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--check", action="store_true", help="只检查，不修改")
    group.add_argument("--apply", action="store_true", help="应用修补")
    group.add_argument("--restore", action="store_true", help="从备份还原")
    group.add_argument("--status", action="store_true", help="机器可读状态（0=已完成，3=待修补，4=缺替代符号）")
    group.add_argument("--list-symbols", action="store_true", help="列出所有被引用的符号")
    ap.add_argument("-f", "--file", help="steamclient.so 路径（默认自动查找）")
    args = ap.parse_args()

    elf = Elf32(find_steamclient(args.file))
    if args.status:
        return cmd_status(elf, DEFAULT_MAP)
    if args.check:
        return cmd_check(elf, DEFAULT_MAP)
    if args.list_symbols:
        return cmd_list(elf)
    if args.apply:
        return cmd_apply(elf, DEFAULT_MAP)
    return cmd_restore(elf)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Elf32Error as exc:
        print(f"错误：{exc}", file=sys.stderr)
        sys.exit(2)
