# Portal 2 启动与渲染排查 · 要点摘要（2026-10-01）

> 完整原文包含大量本机路径与逐条命令行，已从仓库移除；此处只保留可复用的结论。

## 结论

1. **box64 不是方案**：Portal 2 全链路是 32 位（`portal2_linux`、`bin/*.so`、`bin/linux32/*.so`），
   box64 不支持 32 位 ELF。
2. **box86 能加载引擎**，但在 64KB 页内核上会触发堆损坏崩溃，需要 4K 页内核环境（TSO 方案）。
3. **FEX-Emu 路线**：GL thunk 必须在正确位置注入；Steam 套上的 scout-on-soldier 容器会把
   x86 Mesa 换成 rootfs 里那套没有 panfrost 驱动的版本，最终落到 llvmpipe 软渲染。
4. **不要手拼容器链**：正解是不套容器直跑，由兼容工具注入 `STEAM_COMPAT_FEX_CONFIG`。
5. **花屏有两种诱因**：mesa 版本（26.0.8 存在 panfrost bug，26.2.4~kisak 正常），
   以及谎报 GL/GLSL 版本（`MESA_GL_VERSION_OVERRIDE` 之类）。
6. **字体/中文渲染问题独立于渲染路径**，换驱动不会好。
7. **进程识别**：FEX 下 `comm` 会变成 `exe`，`pgrep -x` 会漏；box86 下 `comm` 正常。

## 可复用的排查手法

- 在游戏包装脚本里 `export LD_DEBUG=libs` + `LD_DEBUG_OUTPUT`，可拿到容器内动态库加载全轨迹。
- Xwayland 下 `ffmpeg x11grab` 抓不到游戏窗口，用 python-xlib `GetImage` 按窗口抓。
- 判断是否软渲：`ps -L` 数 llvmpipe 线程，或 `glxinfo -B` 看 renderer。
