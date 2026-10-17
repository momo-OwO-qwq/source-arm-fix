# Half-Life 2 在 RK3588 + box86 上的启动卡顿排查记录

> 记录时间：2026-10-17 晚
> 环境：RK3588（Mali-G610 / Panfrost，Mesa 26.2.4）+ box86 v0.3.9 +
> Steam 2026-10-17 客户端 + Half-Life 2（AppID 220，20 周年更新后的 `hl2_complete` 分支）

## 1. 现象

- Steam 里点「开始游戏」，能进但**启动阶段明显卡顿**（长时间黑屏/无响应感），
  进地图后前几十秒还在持续掉帧。
- 进程存活时间不固定（实测两次分别约 3 分 41 秒、45 秒），与 `steamclient.so`
  那条 70 秒崩溃路径**不是同一个问题**——SteamAPI 初始化是成功的。

## 2. 根因（三条，按影响排序）

### 2.1 启动走了 FEX-Emu + scout 容器，而不是 box86

`~/.local/share/Steam/logs/gameprocess_log.txt` 里能看到 Steam 拉起的是：

```
.../FEX-Emu/fex-compat-tool ... steam-launch-wrapper -- reaper SteamLaunch AppId=220 -- .../hl2.sh -steam -game hl2_complete
```

即和当初 Portal 2 软渲那条路同源：整条链路跑在 FEX 翻译 + pressure-vessel 容器里，
库路径被容器接管。`config.vdf` 的 `CompatToolMapping` 只显式映射了 620（Portal 2），
220 是走默认兼容工具落进来的。

用 box86 直启后，`ps -L` 中 **llvmpipe 线程数 0**，GPU 从 300MHz 拉到 1000MHz，
说明拿到的是 Panfrost 硬渲。

### 2.2 完全没有着色器缓存，每次启动都重新编译

首启日志：

```
Could not load program cache file glbaseshaders.cfg
Could not find base GL shader cache file
Could not load program cache file glshaders.cfg
Precache: Took 0 ms, Vertex 0, Pixel 0
```

`Half-Life 2/` 下既没有 `glbaseshaders.cfg` 也没有 `glshaders.cfg`（对照组：
Portal 2 有 `portal2/glbaseshaders.cfg`、`update/glshaders.cfg`）。
没有缓存 → 引擎只能边跑边 `CreatePixelShader` 逐个组合现场编译 GLSL，
ARM + box86 上这就是启动卡顿与进图后持续掉帧的主体。

关键机制：**`glshaders.cfg` 只在「正常退出」时写回**，写在 `hl2/glshaders.cfg`
（即使 `-game hl2_complete` 也写这里）。`kill -9` 不会写。

### 2.3 画面设置对 Mali-G610 偏重

`hl2/videoconfig_linux.cfg` 原值：1920×1080 + `ScreenMSAA 4` + `mat_forceaniso 16`
+ `mat_hdr_level 2` + `mat_vsync 1`。4×MSAA + 16×AF + HDR 在 G610 上首帧非常吃力，
vsync 还会把掉帧放大成明显顿挫。

## 3. 处理步骤

```bash
# 1) steamclient 补丁（本次已是最新状态，无需再打，仅确认）
cd ~/source-arm-fix
python3 scripts/fix_steamclient.py --status     # 退出码 0 = 干净

# 2) 用仓库脚本启动（注意必须显式指定 -game hl2_complete）
./scripts/play_source.sh "$HOME/.local/share/Steam/steamapps/common/Half-Life 2" \
    -game hl2_complete -novid

# 3) 首次进一次地图（例如 +map d1_trainstation_01），然后正常退出：
#    窗口焦点下 ALT+F4。确认缓存落地：
ls -l "$HOME/.local/share/Steam/steamapps/common/Half-Life 2/hl2/glshaders.cfg"

# 4) 之后的启动就会命中缓存
```

画面设置（`hl2/videoconfig_linux.cfg`，改前先备份）：

| 项 | 原值 | 建议 | 理由 |
|---|---|---|---|
| `mat_antialias` | 4 | 0 | MSAA 对 G610 太贵 |
| `mat_forceaniso` | 16 | 4 | 16×AF 收益小、带宽开销大 |
| `mat_vsync` | 1 | 0 | 掉帧时不叠加顿挫 |
| `mat_hdr_level` | 2 | 保持 2 | 观感优先，卡再降 |

## 4. 实测数据

| 指标 | 无缓存（首启） | 有缓存（二次启动） |
|---|---|---|
| 到 `server.so loaded`（菜单） | 21.0 s | 13.0 s |
| `Precache` | `0 ms, Vertex 0, Pixel 0` | `689 ms, Vertex 336, Pixel 796` |
| 地图内 `CreatePixelShader` 刷屏 | 大量 | 0 行 |
| llvmpipe 线程 | 0 | 0 |
| GPU 频率（地图内） | — | 1000 MHz |
| `hl2/glshaders.cfg` | 不存在 | 8318 B → 10119 B（进一次地图后增长） |

## 5. 已知残留

- **`Timed out waiting for game mapping!` 约 9–10 秒**：出现在手动（非 Steam 树内）
  启动时，占启动时间近一半。已验证无效的手段：`SteamAppId`/`SteamGameId`、
  `SteamClientLaunch=1`、`SteamEnv=1`、`SteamPath`、`-steam`。
  推测与 Steam 客户端的 content mapping 绑定进程树有关，暂未解决，不影响可玩性。
- **`sourcevr.so` / `stdshader_dbg.so` dlopen 失败**：box86 缺符号所致，
  引擎回退到非 VR 路径，可忽略。
- Steamos 里直接点「开始游戏」仍会走 FEX；要吃到本记录的收益，需用脚本启动。

## 6. 附带修复的脚本 bug

`scripts/play_source.sh` 原来没有 `cd` 到游戏目录，HL2 会立即打印
`Failed to load the launcher` 退出（引擎按相对路径找资源）。
现已在 `exec` 前加 `cd "$GAME_DIR"`，对所有起源引擎游戏通用。

## 7. 退出方式备忘

- `ALT+F4`（`xdotool windowactivate --sync <win>; xdotool key alt+F4`）有效，会正常
  走引擎 Shutdown 并写着色器缓存。
- `wmctrl -ic <win>` 对 SDL 窗口无效，别用。
- `kill -9` 能清进程，但**不写缓存**，等于白预热一次。
