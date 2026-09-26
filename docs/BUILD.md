# Building

`build.sh` builds every open-source component from pinned sources ([versions.env](../versions.env)) into
`out/`. It works on x86_64 or aarch64 Linux, and all output is Windows ARM64 (`aarch64-w64-mingw32`).

## Requirements

Debian/Ubuntu packages:

```sh
sudo apt install git curl python3 make gcc flex bison autoconf perl \
                 cmake ninja-build meson glslang-tools
```

`build.sh` downloads the llvm-mingw toolchain (pinned release) itself.

The `monomod` step also needs a **.NET 10 SDK** with `dotnet` on `PATH`
(https://dot.net/v1/dotnet-install.sh). Without it, the step is skipped.

On Ubuntu, `needrestart` can block an unattended `apt` behind an interactive prompt. Use
`sudo NEEDRESTART_MODE=a apt install …`.

## Steps

```sh
./build.sh                 # everything
./build.sh steam-api dxvk  # selected steps
```

| Step | What it does |
|---|---|
| `toolchain` | download llvm-mingw into `deps/` |
| `fetch` | clone Proton (tag), Wine (Proton's submodule commit), DXVK (Proton's commit, with submodules), OpenXR-SDK (tag); download zlib and Mono's `zlib-helper.c` |
| `wine-tools` | `autoreconf`, `make_specfiles`, `make_makefiles`, `make_vulkan`, then a tools-only `configure` and build of `widl`, `winebuild`, and every IDL-generated header |
| `lsteamclient` | Proton `lsteamclient/*.c` (Windows half) → `lsteamclient_a64.dll`, exports from its `.spec`, Wine builtin marker |
| `wineopenxr` | Proton `wineopenxr/{openxr_loader,loader_thunks}.c` → `wineopenxr_a64.dll`, import libs for `winevulkan`/`ntdll` generated with `winebuild --def` |
| `steam-api` | `gen.py` (flat API wrappers) + `gen_sdk_inline.py` + core/helpers → `steam_api64.dll` |
| `openxr-loader` | apply patch, CMake + Ninja → `openxr_loader.dll` |
| `dxvk` | apply patches, Meson cross build → `dxgi.dll`, `d3d11.dll` |
| `monoposixhelper` | `zlib-helper.c` + zlib → `MonoPosixHelper.dll` |
| `doorstop` | BSIPA's Doorstop + generated ARM64 winhttp stubs → `winhttp.dll` |
| `monomod` | MonoMod at BSIPA's commit + ABI patch → `MonoMod.Core.dll` (net452) |

A full build from scratch takes about 15–20 minutes, mostly Wine's header generation and DXVK.

## Keeping in sync with Proton

`lsteamclient_a64.dll` and `wineopenxr_a64.dll` must be built from the **same Proton version** that
runs the game. Their unix halves are Proton's own `.so` files, and the parameter structs and call
numbers change between versions. When Steam updates "Proton 11.0 (ARM64)":

1. Read the new version from `<Proton dir>/version` (for example `proton-11.0-2c-arm64`).
2. Set `PROTON_TAG` to the matching tag of github.com/ValveSoftware/Proton, and set `WINE_COMMIT` and
   `DXVK_COMMIT` to that tag's submodule commits (`git -C Proton submodule status`).
3. `rm -rf deps obj out && ./build.sh`, then reinstall.

## Checks

- Every output DLL must be `IMAGE_FILE_MACHINE_ARM64` (`0xaa64`).
- `steam_api64.dll` must export everything the real one does (1,089 symbols).
- [tools/smoketest.cpp](../tools/smoketest.cpp): a minimal ARM64 exe that loads `lsteamclient_a64.dll`
  and prints your SteamID, login state, app ID and persona name. Build and run:
  ```sh
  deps/llvm-mingw/bin/aarch64-w64-mingw32-clang++ -O2 -Iobj/steam-api/inc -Isrc/steam-api \
      tools/smoketest.cpp obj/steam-api/flat_generated.o -o smoketest.exe -static
  # on the device, with WINEDLLPATH set up and lsteamclient_a64.dll next to the exe:
  WINEDLLPATH=… proton run smoketest.exe   # writes the result to Z:\home\steamos\smoke.log
  ```
- [tools/loadtest.c](../tools/loadtest.c): `LoadLibrary` any DLL and print the error; run with
  `WINEDEBUG=+loaddll,+module` to see why a module fails to load.
