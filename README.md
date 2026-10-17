# source-arm-fix

**中文** | [English](README.en.md)

在 **ARM（aarch64）+ box86** 环境里运行 Steam 版 **32 位起源引擎游戏**时，
解决「启动约 70 秒后崩溃退出」以及「`dlopen client.so error=2`」两类问题。

适用于：Portal 2、Half-Life 2 系列、Team Fortress 2、CS:S、L4D2、Garry's Mod
等一切依赖 `steamclient.so` 的 32 位 Source 游戏（AppID 不同，机制相同）。

> 已验证环境：RK3588（Mali-G610 / Panfrost，Mesa 26.2.4）+ box86 v0.3.9 +
> Steam 2026-10-17 客户端，游戏 Portal 2 (AppID 620)。

---

## 1. 问题现象

| 现象 | 表面原因 |
|---|---|
| 双击启动后窗口闪一下，约 70 秒后进程消失，日志末尾出现 `Steam is not running` | `SteamAPI_Init()` 失败 |
| 日志里 `Error: Symbol pthread_mutex_clocklock not found.` + `cannot apply R_386_JMP_SLOT` | box86 的 libpthread 封装表里没有这个符号 |
| `dlopen(".../portal2/bin/client.so") failed error=2` | 新版 Steam 把 `.so` 放进了 `<mod>/bin/linux32/`，引擎仍按老路径找 |

## 2. 根因链

```
Steam 自动更新 32 位 steamclient.so
        │
        ├─ 新增 glibc 2.30+ 符号（本例：pthread_mutex_clocklock）
        │
        ├─ box86 的封装表是编译期固定的 → 找不到符号 → 重定位失败
        │
        ├─ libsteam_api 的 SteamAPI_Init() 返回失败
        │
        └─ 引擎判定「Steam 未运行」→ 空指针崩溃 / 自行退出（约 70 秒）
```

关键点：**这和 GPU、渲染、mesa 版本完全无关**。升级驱动、换 llvmpipe 都治不好。

## 3. 修复思路

不重编 box86（它需要一堆本地补丁，重建容易回归），也不改游戏本体，
而是**只改 ELF 的重定位表**：把「缺失符号」的那条 `R_386_JUMP_SLOT`
改指向一个**已存在、调用约定兼容**的符号。

以 `pthread_mutex_clocklock` → `pthread_mutex_lock` 为例：

| 维度 | 说明 |
|---|---|
| 调用约定 | cdecl，参数从右向左压栈、调用方清栈；多传的 `clockid` 被忽略 |
| 返回值 | 都是 `int`（0 / 错误码），语义一致 |
| 语义差异 | 失去「超时」能力，退化为阻塞加锁 |
| 改动范围 | `.rel.plt` 中 4 字节的符号索引，不动代码段 |

改完之后 box86 能正常解析该 GOT 项，`SteamAPI_Init()` 通过，游戏进入主菜单。

## 4. 使用

### 一键（推荐）

```bash
git clone <this-repo> source-arm-fix && cd source-arm-fix
./install.sh              # 检查 → 修补 → 自检，自动备份
./install.sh --dry-run    # 只预览，不修改
./install.sh --yes        # 跳过确认
./install.sh --restore    # 回滚
./install.sh --file /path/to/steamclient.so   # 指定文件（多 Steam 目录时）
```

`install.sh` 的自检不是摆设：它会用 `--status` 复核「已无待修补项」，
再独立校验一次 ELF 结构，两步都过才算成功（退出码 0）。

### 手动

```bash
# 1) 先检查（只读）
python3 scripts/fix_steamclient.py --check

# 2) 应用修补（自动备份为 steamclient.so.bak-source-arm-fix）
python3 scripts/fix_steamclient.py --apply

# 3) 机器可读状态：0=已完成，3=待修补，4=替代符号缺失
python3 scripts/fix_steamclient.py --status

# 4) 需要回滚时
python3 scripts/fix_steamclient.py --restore
```

Steam 每次更新客户端都会覆盖补丁，**更新后重跑 `./install.sh` 即可**。

### 手动启动游戏（可选）

Steam 里直接点「开始游戏」也行；若你想手动带参数启动：

```bash
./scripts/play_source.sh "$HOME/.local/share/Steam/steamapps/common/Portal 2" \
    -game portal2 +map sp_a1_intro1 +cl_showfps 2

DRY_RUN=1 ./scripts/play_source.sh "<游戏目录>"   # 只打印命令
CPUS=6-7 ./scripts/play_source.sh "<游戏目录>"     # 指定绑核
```

脚本会自动：

1. 用启动器名推断 mod 目录（`portal2_linux` → `portal2`）；
2. 把 `<mod>/bin/linux32`、`bin/linux32`、`<mod>/bin`、`bin` 依次加进
   `LD_LIBRARY_PATH`（解决 `client.so error=2`）；
3. 用 `taskset` 绑大核。

## 5. Half-Life 2（`hl2_complete`）补充

2026-10-17 在 HL2（AppID 220）上复验，除了本文的符号补丁，还有三处必须处理，
否则表现是「启动卡顿」而不是崩溃。完整记录见 [docs/half-life-2.md](docs/half-life-2.md)。

```bash
./scripts/play_source.sh "$HOME/.local/share/Steam/steamapps/common/Half-Life 2" \
    -game hl2_complete -novid
```

1. **必须显式 `-game hl2_complete`**：20 周年更新后 Steam 主启动项用的是
   `hl2_complete`，而脚本按启动器名 `hl2_linux` 推断会得到 `hl2`。
2. **首次启动会现场编译全部着色器**：HL2 目录里既无 `glbaseshaders.cfg` 也无
   `glshaders.cfg`（Portal 2 是有的），日志会出现
   `Could not find base GL shader cache file` 和 `Precache: Took 0 ms, Vertex 0, Pixel 0`。
   缓存只在**正常退出**时写回 `hl2/glshaders.cfg`，`kill -9` 不写。
   做法：进一次地图（如 `+map d1_trainstation_01`）→ 窗口 `ALT+F4` 正常退出。
   实测二次启动到菜单从 21.0s 降到 13.0s，`Precache` 变为 336 顶点 / 796 像素。
3. **画面设置偏重**：`mat_antialias 4` + `mat_forceaniso 16` + `mat_vsync 1` 对
   Mali-G610 太重，建议 0 / 4 / 0。

已知残留：手动启动时 `Timed out waiting for game mapping!` 会耗掉约 9–10 秒，
`SteamAppId`、`SteamClientLaunch`、`-steam` 均无法消除，待后续处理。

## 6. 适配其他起源引擎游戏

符号补丁是**全局的**（`~/.local/share/Steam/linux32/steamclient.so` 被所有
32 位 Steam 游戏共用），所以一次修补即可覆盖全部游戏。

如果换游戏后 box86 报的是**另一个**缺失符号，按下面步骤扩展：

```bash
# 1) 看 box86 的原始报错，拿到符号名，例如 pthread_cond_clockwait
# 2) 确认替代符号存在
python3 scripts/fix_steamclient.py --list-symbols | grep -i pthread
# 3) 在 scripts/fix_steamclient.py 的 DEFAULT_MAP 里加一行
#    "pthread_cond_clockwait": "pthread_cond_timedwait",
# 4) 重新 --check / --apply
```

新增映射的判断标准：

- **参数**：cdecl 下可以多，不能少；缺失的必填参数会导致读到垃圾指针。
- **返回值**：类型一致，错误码语义一致。
- **语义**：退化后仍安全（例如「去掉超时」比「去掉加锁」安全得多）。

## 7. 验证清单

```bash
# 进程是否活着（超过 2 分钟基本就稳了）
pgrep -x portal2_linux

# 是否真的跑在 GPU 上：应无 llvmpipe 线程
ps -L -p $(pgrep -x portal2_linux) | grep -c llvmpipe   # 期望 0

# GPU 频率应拉高（RK3588 常见 300MHz 空闲 → 1000MHz 满载）
watch -n1 cat /sys/class/devfreq/*gpu*/cur_freq
```

## 8. 注意事项

- 修改的是 Steam 客户端自己的库文件，**仅影响本机**；请自行评估风险并保留备份。
- 本工具不含任何绕过授权、破解或盗版相关内容，只修复动态链接兼容性。
- 若 Steam 校验/更新后问题复发，属预期行为，重跑 `--apply` 即可。
- 已知限制：失去超时语义。若某游戏在极端情况下出现「加锁卡死」，
  可以用 `--restore` 回滚，并改用重编 box86 的方案。

## 9. 目录结构

```
install.sh             # 一键：检查 → 修补 → 自检（--dry-run / --yes / --restore）
scripts/
  fix_steamclient.py   # ELF 重定位改指工具（check / apply / restore / status / list）
  play_source.sh       # 通用启动脚本（LD_LIBRARY_PATH + 绑核）
docs/
  background.md        # 完整排查过程与判据
  half-life-2.md       # HL2 启动卡顿（着色器缓存 / 启动方式）实测
  portal2-2026-10-11-continuation.md  # Portal 2 续篇要点摘要（steamclient 符号 / dynarec 缺口）
  portal2-2026-10-01-full-investigation.md  # Portal 2 全记录要点摘要（FEX/TSO/thunks/花屏）
README.en.md           # English README
```

## License

MIT
