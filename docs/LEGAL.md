# Licensing and redistribution

**This is not legal advice.** It describes how the project is laid out so it can be published safely.

## What this repository contains

Only original code, patches, and scripts. It holds **no** third-party binaries, and no third-party
source except what the build downloads from upstream.

| Path | Origin | License |
|---|---|---|
| `src/steam-api/*` | original; generates code from Steamworks SDK headers **at build time**, taken from the Proton checkout | project license (see below) |
| `src/unityopenxr/patch_unityopenxr.py`, `tools/*`, `install/*`, `build.sh` | original | project license |
| `src/monoposixhelper/glib.h`, `config.h` | original shim | project license |
| `patches/openxr-loader/*` | changes to the Khronos OpenXR-SDK | Apache-2.0 (upstream) |
| `patches/dxvk/*` | changes to DXVK | zlib (upstream) |

The Steamworks SDK headers aren't copied into this repo. The build reads them from Proton's public
repository, which carries them in `lsteamclient/steamworks_sdk_*`. `sdk_inline_impl.inc` and
`flat_generated.cpp` are generated into `obj/` and are not committed.

## What the build produces (`out/`)

| File | Built from | License |
|---|---|---|
| `lsteamclient_a64.dll`, `wineopenxr_a64.dll` | Proton sources + Wine (`winecrt0`) | LGPL-2.1+ (Wine/Proton), BSD-3 for some Proton parts; see Proton's `LICENSE` |
| `openxr_loader.dll` | Khronos OpenXR-SDK | Apache-2.0 |
| `dxgi.dll`, `d3d11.dll` | DXVK | zlib |
| `MonoPosixHelper.dll` | Mono `zlib-helper.c` (MIT) + zlib (zlib) | MIT + zlib |
| `steam_api64.dll` | this project | project license |

Anyone distributing the built binaries must follow those licenses. For the LGPL parts, that means
offering the corresponding source; pointing to the pinned upstream tags plus this repo does that.

## What is downloaded on the user's machine and never redistributed

| File | Source | Why it isn't redistributed |
|---|---|---|
| Unity Windows ARM64 player (`WindowsPlayer.exe`, `UnityPlayer.dll`, `UnityCrashHandler64.exe`, `mono-2.0-bdwgc.dll`) | Unity's download CDN | Unity runtime binaries: the Unity licence lets them ship inside a game built by a Unity licensee, not on their own |
| `UnityOpenXR.dll` (ARM64) | Unity package registry, com.unity.xr.openxr 1.14.3 | Unity Companion License; patched locally |
| `vcruntime140*.dll`, `msvcp140.dll` | Microsoft `vc_redist.arm64.exe` | Microsoft Visual C++ redistributable terms |

`install/bs-arm64.sh fetch` downloads and patches these on the user's machine.

## The game

Beat Saber's files, and the user's ownership of the game, are required and are verified through Steam
as usual. The install **replaces the game's engine binaries** in a local copy; no game data or code is
changed. It's comparable to how mod loaders work, but check Beat Games' terms before publishing, and
make the project name and README clearly unofficial. "Beat Saber" is a trademark of Beat Games.

## Project license

Not chosen yet. MIT or zlib would fit the original code and match DXVK and Mono. Choose one before
publishing, and add a `LICENSE` file.
