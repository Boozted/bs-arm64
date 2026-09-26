# Installing and running

The installer is `install/bs-arm64.sh`. It runs on the device (Steam Frame, SteamOS) and needs only
`bash`, `python3`, `curl`, `tar` and `bsdtar`, which ship with SteamOS. It also needs:

- a **Beat Saber 1.44.1** instance, e.g. from BSManager (`~/.local/share/BSManager/BSInstances/1.44.1`)
- **Proton 11.0 (ARM64)**, the exact version the DLLs were built for
- the Wine prefix already created: launch any game with it once. The default is BSManager's shared
  prefix `~/.local/share/BSManager/SharedContent/compatdata`.
- `out/` from `build.sh` (copy the whole repo to the device, or pass `--artifacts DIR`)

Work on a **copy** of an instance. BSManager can duplicate instances.

## Commands

```sh
install/bs-arm64.sh fetch                 # download Unity player, UnityOpenXR, VC++ runtime (cached)
install/bs-arm64.sh install   <instance>  # patch the instance and set up the prefix (runs fetch)
install/bs-arm64.sh launch    <instance>  # start it (log: /tmp/bs-arm64.log); --debug for verbose logs
install/bs-arm64.sh uninstall <instance>  # restore the x64 files
```

Options: `--artifacts DIR`, `--cache DIR` (default `~/.cache/bs-arm64`), `--prefix DIR`,
`--proton DIR`.

`fetch` streams the ~500 MB Unity package once and keeps about 40 MB.

## What `install` changes

In the instance (the originals go to `<instance>/.bs-arm64/backup/`, and added files are listed in
`.bs-arm64/added`):

| File | Replaced by |
|---|---|
| `Beat Saber.exe` | Unity ARM64 `WindowsPlayer.exe` |
| `UnityPlayer.dll`, `UnityCrashHandler64.exe` | Unity ARM64 |
| `MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll` | Unity ARM64 |
| `MonoBleedingEdge/EmbedRuntime/MonoPosixHelper.dll` | built (zlib helper) |
| `dxgi.dll`, `d3d11.dll` (new) | built (DXVK aarch64) |
| `vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll` (new) | Microsoft ARM64 runtime |
| `openxr_loader.dll` (new, next to the exe) | built |
| `Beat Saber_Data/Plugins/ARM64/` (new) | `steam_api64.dll`, `lsteamclient_a64.dll`, `UnityOpenXR.dll` (patched), `openxr_loader.dll` |

The game data and `Managed/*.dll` are not touched. The x64 plugins stay in `Plugins/x86_64/`, where the
ARM64 player ignores them.

In the prefix:

| Item | Purpose |
|---|---|
| `pfx/drive_c/bs-arm64/aarch64-windows/{lsteamclient_a64,wineopenxr_a64}.dll` | Wine builtins, found through `WINEDLLPATH` |
| `pfx/drive_c/bs-arm64/aarch64-unix/*.so` | symlinks to Proton's `lsteamclient.so` / `wineopenxr.so` |
| `pfx/drive_c/bs-arm64/wineopenxr_a64.json` | OpenXR runtime manifest for ARM64 processes |
| `pfx/drive_c/bs-arm64/proton-version` | Proton build these must match |
| `HKLM\Software\Khronos\OpenXR\1` `ActiveRuntimeARM64` | read by our `openxr_loader.dll` before `ActiveRuntime` |

x64 games in the same prefix are unaffected: they ignore the ARM64 value and directory.

## Launching

`launch` runs `proton run "Beat Saber.exe"` with the usual Steam and Proton variables plus:

- `WINEDLLPATH=<prefix>/pfx/drive_c/bs-arm64`
- `DISABLE_VULKAN_FDM_INJECTION_LAYER=1`
- `DISPLAY=:0` and `XDG_RUNTIME_DIR`, only if unset (e.g. started over SSH). Without a display, the
  player hangs silently right after start.

SteamVR must be running, which it always is in the Frame's game mode. SteamVR recognizes the game as
`steam.app.620980`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `[Steam] Not being able to initialize the platform` | `steam_api64.dll` not in `Plugins/ARM64`, or `WINEDLLPATH` missing; run `launch --debug` and look for `steam_api64(arm64)` lines |
| `DllNotFoundException: UnityOpenXR` | `Plugins/ARM64/UnityOpenXR.dll` missing, or msvcp140/vcruntime140 missing |
| `xrCreateInstance: XR_ERROR_RUNTIME_UNAVAILABLE` | registry value or JSON missing; `launch --debug` shows the loader's messages as `debugstr` lines |
| `xrCreateSession: XR_ERROR_VALIDATION_FAILURE` | WineD3D in use instead of DXVK: `dxgi.dll`/`d3d11.dll` not next to the exe, or `PROTON_USE_WINED3D` set |
| crash in `unityopenxr` / `ucrtbase` on recenter | Microsoft VC++ runtime missing next to the exe |
| back to menu with "Could not load readonly beatmap level data" | x64 `MonoPosixHelper.dll` still in place |
| game process idles at 0 % CPU, no `Player.log` | no X display; set `DISPLAY` (launch defaults to `:0`) |
| `launch` refuses: "Proton changed" | rebuild for the new Proton and reinstall (see BUILD.md) |

The game log is at `<prefix>/pfx/drive_c/users/steamuser/AppData/LocalLow/Hyperbolic Magnetism/Beat Saber/Player.log`.
SteamVR's per-session stats are in `~/.local/share/Steam/logs/vrcompositor.txt` (search for
`Cumulative stats for pid`).
