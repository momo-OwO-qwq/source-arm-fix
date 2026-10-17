# source-arm-fix

Fix **32-bit Source-engine games on ARM (aarch64) + box86** that crash ~70 seconds
after launch, or fail with `dlopen client.so error=2`.

Applies to Portal 2, Half-Life 2 (and episodes), Team Fortress 2, CS:S, L4D2,
Garry's Mod — any 32-bit Source title that loads `steamclient.so`.

> Tested on RK3588 (Mali-G610 / Panfrost, Mesa 26.2.4) + box86 v0.3.9 +
> Steam client of 2026-10-17, with Portal 2 (AppID 620).

---

## 1. Symptoms

| Symptom | What it really means |
|---|---|
| Window flashes, process disappears after ~70 s, log ends with `Steam is not running` | `SteamAPI_Init()` failed |
| `Error: Symbol pthread_mutex_clocklock not found.` + `cannot apply R_386_JMP_SLOT` | box86 has no wrapper for that glibc symbol |
| `dlopen(".../portal2/bin/client.so") failed error=2` | newer Steam moved the `.so` into `<mod>/bin/linux32/` |

## 2. Root cause

```
Steam auto-updates the 32-bit steamclient.so
    └─ it now needs glibc 2.30+ symbols (here: pthread_mutex_clocklock)
        └─ box86's wrapper table is fixed at build time → symbol not found → relocation fails
            └─ SteamAPI_Init() returns failure
                └─ engine thinks "Steam is not running" → null-deref crash / self-exit (~70 s)
```

**This has nothing to do with GPU, drivers, or Mesa.** Upgrading the graphics stack
will not help.

## 3. How the fix works

Instead of rebuilding box86 (which carries local patches and is easy to regress),
or modifying the game, we touch **only the ELF relocation table**: the
`R_386_JUMP_SLOT` entry for the missing symbol is redirected to an existing symbol
with a compatible calling convention.

For `pthread_mutex_clocklock` → `pthread_mutex_lock`:

| Aspect | Detail |
|---|---|
| Calling convention | cdecl: caller cleans the stack, extra `clockid` argument is ignored |
| Return value | both `int` (0 / errno) |
| Semantic change | timeout is lost, the call blocks instead |
| Blast radius | 4 bytes of symbol index in `.rel.plt`, code section untouched |

After that, box86 resolves the GOT slot, `SteamAPI_Init()` succeeds, and the game
reaches its main menu.

## 4. Usage

```bash
git clone <this-repo> source-arm-fix && cd source-arm-fix

# one-shot: check → patch → self-test (backup created automatically)
./install.sh

# non-interactive / preview / rollback
./install.sh --yes
./install.sh --dry-run
./install.sh --restore
./install.sh --file /path/to/steamclient.so
```

Manual control (same logic, finer granularity):

```bash
python3 scripts/fix_steamclient.py --check     # read-only
python3 scripts/fix_steamclient.py --apply     # patch (+ backup)
python3 scripts/fix_steamclient.py --status    # exit 0 ok / 3 pending / 4 missing alt
python3 scripts/fix_steamclient.py --restore
```

Steam overwrites `steamclient.so` on every client update — **re-run `./install.sh`
after updating Steam**.

### Launching a game manually (optional)

```bash
./scripts/play_source.sh "$HOME/.local/share/Steam/steamapps/common/Portal 2" \
    -game portal2 +map sp_a1_intro1 +cl_showfps 2

DRY_RUN=1 ./scripts/play_source.sh "<game dir>"   # print the command only
CPUS=6-7 ./scripts/play_source.sh "<game dir>"     # pin to specific cores
```

The launcher:

1. infers the mod directory from the engine binary name (`portal2_linux` → `portal2`);
2. prepends `<mod>/bin/linux32`, `bin/linux32`, `<mod>/bin`, `bin` to
   `LD_LIBRARY_PATH` (fixes `client.so error=2`);
3. pins the process with `taskset`.

## 5. Adding support for other titles

The patch is global — `~/.local/share/Steam/linux32/steamclient.so` is shared by all
32-bit Steam games, so one patch covers them all.

If a different title trips over a **different** missing symbol:

```bash
# 1) read the symbol name from box86's error, e.g. pthread_cond_clockwait
# 2) confirm a replacement exists
python3 scripts/fix_steamclient.py --list-symbols | grep -i pthread
# 3) add one line to DEFAULT_MAP in scripts/fix_steamclient.py
#    "pthread_cond_clockwait": "pthread_cond_timedwait",
# 4) re-run --check / --apply
```

Rules for a safe mapping:

- **Arguments**: cdecl allows extra arguments, never fewer — a missing required
  argument means a garbage pointer.
- **Return value**: same type, same error-code semantics.
- **Behaviour**: degradation must stay safe ("lose the timeout" is fine,
  "lose the lock" is not).

## 6. Verification

```bash
pgrep -x portal2_linux                                  # process survives > 2 min
ps -L -p $(pgrep -x portal2_linux) | grep -c llvmpipe   # expect 0 (no software GL)
watch -n1 cat /sys/class/devfreq/*gpu*/cur_freq         # 300 MHz idle → ~1000 MHz loaded
```

## 7. Caveats

- You are modifying a Steam client library, locally; keep the backup, judge the risk yourself.
- This project contains no DRM circumvention — it only repairs dynamic-link compatibility.
- After a Steam update, the symptom returns by design. Re-run the installer.
- Known limitation: timeouts are lost. If a title ever deadlocks, use `--restore`
  and switch to rebuilding box86 instead.

## 8. Layout

```
install.sh               # one-shot: check → patch → self-test
scripts/
  fix_steamclient.py     # ELF relocation redirect tool
  play_source.sh         # generic launcher (LD_LIBRARY_PATH + CPU pinning)
docs/
  background.md          # full investigation log and ruled-out approaches
```

## License

MIT
