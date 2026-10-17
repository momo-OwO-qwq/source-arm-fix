# 排查过程与判据（2026-10-17）

记录一次真实排查：RK3588 上 Portal 2 从「能进菜单」到「启动即崩」，
以及如何一步步把范围收敛到 steamclient.so 的一个符号。

## 0. 环境

| 项 | 值 |
|---|---|
| 主机 | RK3588（4×A76 + 4×A55），Mali-G610 MC4 |
| 系统 | Ubuntu 26.04 arm64 |
| 图形 | Panfrost，Mesa 26.2.4，OpenGL 3.1 / Vulkan 1.4.354 |
| 模拟层 | box86 v0.3.9（本地构建），binfmt_misc 将 i386 交给 box86 |
| 游戏 | Portal 2（Steam AppID 620），纯 32 位 i386 |

## 1. 先分清「渲染层」和「进程层」

用户的主观感受是「GPU 用不上」，但需要先判定到底哪一层出问题：

```bash
glxinfo -B | grep -iE 'renderer|Accelerated'   # 驱动是否正常
ps -L -p $(pgrep -x portal2_linux) | grep -c llvmpipe   # 是否回退软渲染
cat /sys/class/devfreq/*gpu*/cur_freq          # GPU 是否被拉起来
```

本次结论：驱动健康，游戏进程运行时 **无 llvmpipe 线程**、GPU 到 1000MHz，
说明硬渲路径本来就是通的 —— GPU 没问题，是进程活不下来。

## 2. `client.so error=2` 不是缺文件

日志：

```
dlopen(".../portal2/bin/client.so") failed error=2
```

但实际文件在 `portal2/bin/linux32/client.so`。引擎只查 `<mod>/bin/`，
新版 Steam 把 `.so` 挪进了 `linux32/` 子目录。补一条 `LD_LIBRARY_PATH` 即解决：

```bash
LD_LIBRARY_PATH="$GAME/bin/linux32:$GAME/portal2/bin/linux32"
```

## 3. 真正的死因：steamclient.so 的符号

补完路径后，日志里只剩一条硬错误：

```
Error: Symbol pthread_mutex_clocklock not found.
Error: Relocation error: ... cannot apply R_386_JMP_SLOT ...
```

- `~/.local/share/Steam/linux32/steamclient.so` 的 mtime 显示它**当天 07:02 被更新**；
- 新版本依赖 `pthread_mutex_clocklock`（GLIBC_2.30），box86 封装表里没有；
- 重定位失败 → `SteamAPI_Init()` 失败 → 崩溃栈里能还原出 `Steam is not running` 字符串；
- 退出时间稳定在 70 秒左右。

对照六天前的成功记录：同样的 mesa、同样的 box86，只有 steamclient.so 变了。
**变量唯一**，可以定案。

## 4. 排除过的方案

| 方案 | 结果 | 原因 |
|---|---|---|
| 重编 box86，自己加该符号的封装 | 失败 | 新构建崩在 `__pthread_cond_timedwait64`：宿主 armhf 已是 time64，cond 结构需要映射，旧二进制带本地补丁，上游没有 |
| 手写一个 i386 小库导出该符号 + `BOX86_LD_PRELOAD` | 失败 | box86 的符号查找只搜 wrapped 库表，不认 guest 预加载 ELF 导出的符号 |
| 切 FEX 兼容工具 | 不可行 | 系统 `binfmt_misc` 把 i386 直接交给 box86；Steam 对「有原生 Linux 版」的游戏不套兼容工具 |
| 改 `steamclient.so` 的 `.dynstr` 符号名 | 不可行 | 改指 `pthread_mutex_timedlock` 会导致参数错位（少了 `clockid`） |
| **改重定位表，把 GOT 项指向 `pthread_mutex_lock`** | **成功** | cdecl 下多余参数被忽略，返回值一致 |

## 5. 修补的具体位置

```text
.rel.plt 中的一条 Elf32_Rel：
    r_offset = 0x032ca1dc          # GOT 槽
    r_info   = (114 << 8) | 7      # 符号索引 114 = pthread_mutex_clocklock
改为
    r_info   = (199 << 8) | 7      # 符号索引 199 = pthread_mutex_lock
```

只改 4 个字节，不动代码段，不需要重签名（Linux 无此机制），可随时用备份还原。

## 6. 为什么可以这样改

- i386 cdecl：调用方压参、调用方清栈，被调用方多看到的一个参数不会破坏栈；
- 两者返回值都是 `int`，失败返回错误码，调用方的判断逻辑不变；
- 唯一代价是「没有超时」：原本等不到锁会返回 `ETIMEDOUT`，现在会一直阻塞。

对 Steam 客户端的初始化路径来说，这把锁是短临界区，实测无影响。

## 7. 验证结果

| 指标 | 修补前 | 修补后 |
|---|---|---|
| 进程存活 | 约 70 秒后消失 | 持续运行（实测 >2 分钟并进入交互） |
| 窗口 | 闪一下 | `PORTAL 2 - OpenGL`，`Map State: IsViewable` |
| GPU 频率 | 空载 300MHz | 稳定 1000MHz |
| llvmpipe 线程 | — | 0 |
