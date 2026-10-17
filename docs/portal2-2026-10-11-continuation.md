# Portal 2 排查续篇 · 要点摘要（2026-10-11）

> 完整原文包含大量本机路径与逐条命令行，已从仓库移除；此处只保留可复用的结论。

1. **box64 结论复核不变**：32 位链路不可行。
2. **SteamAPI 第二次 init 失败**：新版 Steam 的 32 位 `steamclient.so` 引用了
   `pthread_mutex_clocklock`（glibc 2.36+ 才引入），box86 符号表未实现 → dlopen 失败、启动即崩。
   该问题由本仓库 `scripts/fix_steamclient.py` 解决；2026-10-17 补丁落地后，
   Half-Life 2 侧每次启动都能看到 `SteamAPI_Init(): Loaded steamclient.so OK.`。
3. **mesa 版本敏感**：26.2.4~kisak1 正常，26.0.8 花屏。
4. **box86 dynarec 缺口**：遇到未实现指令会直接崩；`BOX86_DYNAREC=0` 走解释器可绕过，
   代价是速度。
5. **待办**：box86 调参；32 位 `libvulkan-guest.so` 官方未打包，需自建；字体问题独立跟踪。

详细机制与验证方法见 [background.md](background.md) 与
[portal2-2026-10-01-full-investigation.md](portal2-2026-10-01-full-investigation.md)。
