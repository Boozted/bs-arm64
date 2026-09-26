# bs-arm64: native ARM64 Beat Saber on Proton

Run Beat Saber 1.44.1 as a **native Windows ARM64** program on ARM64 Linux under Proton, tested on the
**Steam Frame**, instead of emulating the x64 build with FEX.

The game's engine and C# code both run natively. Only Proton's small `steam.exe` launcher stays x64.

## Results on the Steam Frame

Numbers come from SteamVR's per-session compositor stats, at a 120 Hz target:

| Build | App CPU / frame | App GPU / frame | Frames reprojected |
|---|---|---|---|
| x64 1.44.1 via FEX (73k frames) | 7.8 ms | 6.6 ms | 26 % |
| x64 1.44.1 via FEX (50k frames) | 8.8 ms | 7.8 ms | 34 % |
| **native ARM64 1.44.1 (76k frames)** | **3.3 ms** | **3.3 ms** | **1.3 %** |

With FEX, the retail game ran at about 90 fps and dipped to about 55. With the native build, the frame drops are gone.

A CPU micro-benchmark run inside the game's Mono runtime shows the same thing: native code is
2–3× faster than FEX-translated x64 on everything except `Vector3` math (see
[docs/FINDINGS.md](docs/FINDINGS.md#benchmark)).

## What works

| Area | Status |
|---|---|
| Menu, maps (official), audio, visuals | ✅ |
| Steam (login, ownership, platform init, online services) | ✅ |
| OpenXR on SteamVR, controllers, recenter | ✅ |
| Burst-compiled code | ⚠️ x64 `lib_burst_generated.dll` can't load; Unity falls back to managed code |
| LIV mixed-reality capture | ❌ no ARM64 `LIV_Bridge.dll` (harmless errors in the log) |
| Mods (BSIPA, Harmony) | ❓ untested |
| Other game versions | ❌ only 1.44.1 (Unity 6000.0.40f1) |

## How it works

The ARM64 player comes from the same Unity version the game was built with (6000.0.40f1). Every native
piece around it that only existed as x64 or ARM64EC has an ARM64 replacement. Details are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

| Piece | Source |
|---|---|
| Unity player, `UnityPlayer.dll`, Mono runtime | Unity's official Windows ARM64 player (downloaded) |
| `steam_api64.dll` | **new**: Steamworks SDK 1.61 flat API ([src/steam-api](src/steam-api)) |
| `lsteamclient_a64.dll` | Proton's lsteamclient, Windows half, rebuilt for pure aarch64 |
| `wineopenxr_a64.dll` | Proton's wineopenxr, Windows half, rebuilt for pure aarch64 |
| `openxr_loader.dll` | Khronos loader 1.1.45, patched ([patches/openxr-loader](patches/openxr-loader)) |
| `UnityOpenXR.dll` | Unity's UWP ARM64 build, imports patched for desktop ([src/unityopenxr](src/unityopenxr)) |
| `dxgi.dll`, `d3d11.dll` | DXVK at Proton's commit, built for aarch64 ([patches/dxvk](patches/dxvk)) |
| `MonoPosixHelper.dll` | Mono's zlib helper + zlib; Unity doesn't ship one for ARM64 |
| `vcruntime140*.dll`, `msvcp140.dll` | Microsoft VC++ ARM64 redistributable (downloaded) |

## Quick start

On the Steam Frame, with BSManager, a 1.44.1 instance, and "Proton 11.0 (ARM64)":

```sh
# 1. build the open-source parts (any Linux host, x86_64 or aarch64); see docs/BUILD.md
./build.sh
# 2. copy the repo (with out/) to the Frame, then there:
install/bs-arm64.sh install ~/.local/share/BSManager/BSInstances/1.44.1
install/bs-arm64.sh launch  ~/.local/share/BSManager/BSInstances/1.44.1
# undo:
install/bs-arm64.sh uninstall ~/.local/share/BSManager/BSInstances/1.44.1
```

See [docs/INSTALL.md](docs/INSTALL.md) for every file that gets touched.

> **Status:** verified end to end on the Frame. A clean `build.sh` output was installed with
> `install/bs-arm64.sh` into a fresh copy of a BSManager 1.44.1 instance: Steam, VR and maps all work.

## Docs

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): every component, and why it's needed
- [docs/BUILD.md](docs/BUILD.md): build requirements and steps
- [docs/INSTALL.md](docs/INSTALL.md): what the installer changes, launching, uninstalling
- [docs/FINDINGS.md](docs/FINDINGS.md): the debugging path, pitfalls, and the benchmark
- [docs/LEGAL.md](docs/LEGAL.md): licenses, and what may or may not be redistributed

## License

MIT (see [LICENSE](LICENSE)) for the original code. The patches follow their upstream licenses. This
project is unofficial and not affiliated with Beat Games, Valve or Unity. See
[docs/LEGAL.md](docs/LEGAL.md).
