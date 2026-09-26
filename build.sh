#!/bin/bash
# Build the open-source parts of the native ARM64 Beat Saber runtime.
#
# Output (out/):
#   lsteamclient_a64.dll  Proton lsteamclient, Windows half, pure aarch64 (Wine builtin)
#   wineopenxr_a64.dll    Proton wineopenxr, Windows half, pure aarch64 (Wine builtin)
#   steam_api64.dll       Steamworks SDK 1.61 flat API on top of lsteamclient_a64
#   openxr_loader.dll     Khronos OpenXR loader 1.1.45 for Windows ARM64 (patched)
#   dxgi.dll, d3d11.dll   DXVK (Proton's commit) for aarch64
#   MonoPosixHelper.dll   Mono's zlib helper (System.IO.Compression) for Windows ARM64
#   patch_unityopenxr.py  copied for install/
#
# Usage: ./build.sh [step...]   steps: toolchain fetch wine-tools lsteamclient wineopenxr
#                                      steam-api openxr-loader dxvk monoposixhelper
#        (default: all, in that order)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")" && pwd)
source "$ROOT/versions.env"
DEPS=$ROOT/deps
OUT=$ROOT/out
OBJ=$ROOT/obj
JOBS=$(nproc)
mkdir -p "$DEPS" "$OUT" "$OBJ"

HOST_ARCH=$(uname -m)
TC=$DEPS/llvm-mingw
CC=$TC/bin/aarch64-w64-mingw32-clang
CXX=$TC/bin/aarch64-w64-mingw32-clang++
DLLTOOL=$TC/bin/aarch64-w64-mingw32-dlltool
PROTON=$DEPS/proton
WINE=$DEPS/wine
WINE_TOOLS=$DEPS/wine-tools

log() { printf '\n==> %s\n' "$*"; }

# Mark a PE file as a Wine builtin so Wine resolves it through WINEDLLPATH and loads
# its unix half (<name>.so) from there.
mark_wine_builtin() {
    python3 - "$1" <<'PY'
import struct, sys
d = bytearray(open(sys.argv[1], 'rb').read())
assert struct.unpack_from('<I', d, 0x3c)[0] >= 0x60, 'DOS stub too small for the builtin marker'
d[0x40:0x60] = b'Wine builtin DLL'.ljust(32, b'\0')
open(sys.argv[1], 'wb').write(d)
PY
}

git_fetch_commit() { # <url> <commit|tag> <dir>
    local url=$1 rev=$2 dir=$3
    [ -d "$dir/.git" ] && return 0
    git init -q "$dir"
    git -C "$dir" remote add origin "$url"
    git -C "$dir" fetch -q --depth 1 origin "$rev"
    git -C "$dir" checkout -q FETCH_HEAD
}

step_toolchain() {
    [ -x "$CC" ] && return 0
    log "llvm-mingw $LLVM_MINGW_VERSION ($HOST_ARCH host)"
    local name=llvm-mingw-$LLVM_MINGW_VERSION-ucrt-ubuntu-22.04-$HOST_ARCH
    curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$name.tar.xz" | tar xJ -C "$DEPS"
    mv "$DEPS/$name" "$TC"
}

step_fetch() {
    log "sources"
    [ -d "$PROTON/.git" ] || git clone -q --depth 1 --branch "$PROTON_TAG" https://github.com/ValveSoftware/Proton.git "$PROTON"
    git_fetch_commit https://github.com/ValveSoftware/wine.git "$WINE_COMMIT" "$WINE"
    if [ ! -d "$DEPS/dxvk/.git" ]; then
        git clone -q https://github.com/ValveSoftware/dxvk.git "$DEPS/dxvk"
        git -C "$DEPS/dxvk" checkout -q "$DXVK_COMMIT"
        git -C "$DEPS/dxvk" submodule update -q --init --recursive
    fi
    [ -d "$DEPS/OpenXR-SDK/.git" ] || git clone -q --depth 1 --branch "$OPENXR_SDK_TAG" https://github.com/KhronosGroup/OpenXR-SDK.git "$DEPS/OpenXR-SDK"
    [ -d "$DEPS/zlib-$ZLIB_VERSION" ] || curl -fsSL "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" | tar xz -C "$DEPS"
    [ -f "$DEPS/zlib-helper.c" ] || curl -fsSL -o "$DEPS/zlib-helper.c" \
        "https://raw.githubusercontent.com/Unity-Technologies/mono/$UNITY_MONO_COMMIT/support/zlib-helper.c"
}

# widl/winebuild plus the IDL-generated and Vulkan headers that Wine-style PE
# modules (lsteamclient, wineopenxr) need. Only tools and headers are built.
step_wine_tools() {
    [ -x "$WINE_TOOLS/tools/winebuild/winebuild" ] && [ -f "$WINE_TOOLS/include/d3d11.h" ] && return 0
    log "wine tools and headers"
    (cd "$WINE" && [ -f configure ] || autoreconf -f)
    (cd "$WINE" && tools/make_specfiles >/dev/null && { tools/make_makefiles >/dev/null 2>&1 || true; })
    (cd "$WINE/dlls/winevulkan" && python3 make_vulkan -x vk.xml -X video.xml)
    mkdir -p "$WINE_TOOLS"
    (cd "$WINE_TOOLS" && PATH=$TC/bin:$PATH "$WINE/configure" -q --without-x --without-freetype \
        --disable-tests --without-gstreamer --without-vulkan --without-wayland --without-alsa \
        --without-pulse --without-dbus --without-gnutls --without-cups --without-sane --without-usb \
        --without-v4l2 --without-krb5 --without-netapi --without-opencl --without-pcap --without-sdl \
        --without-udev --without-unwind --without-gphoto --without-fontconfig >/dev/null)
    local headers
    headers=$(grep -o '^include/[A-Za-z0-9_.]*\.h:' "$WINE_TOOLS/Makefile" | tr -d : | sort -u | grep -v config.h)
    PATH=$TC/bin:$PATH make -C "$WINE_TOOLS" -j"$JOBS" tools/widl/widl tools/winebuild/winebuild >/dev/null
    # shellcheck disable=SC2086
    PATH=$TC/bin:$PATH make -C "$WINE_TOOLS" -k -j"$JOBS" $headers >/dev/null 2>&1 || true
    [ -f "$WINE_TOOLS/include/d3d11.h" ] || { echo "header generation failed" >&2; exit 1; }
}

wine_pe_flags() { # <module source dir>
    local res
    res=$($CC -print-resource-dir)
    echo "-O2 -nostdinc -isystem $res/include -I $1 -I $WINE/include -I $WINE/include/msvcrt -I $WINE_TOOLS/include" \
         "-D__WINESRC__ -D_UCRT -D_WIN32_WINNT=0xa00 -DWINE_NO_TRACE_MSGS -fno-builtin -fms-extensions -Wno-everything"
}

# Import library for a Wine dll, generated from its .spec (exports Wine-internal symbols).
wine_import_lib() { # <module> <out.a>
    local def=$OBJ/$1.def
    "$WINE_TOOLS/tools/winebuild/winebuild" --def -m64 --target aarch64-windows -E "$WINE/dlls/$1/$1.spec" -o "$def"
    "$DLLTOOL" -m arm64 -d "$def" -l "$2"
}

step_lsteamclient() {
    log "lsteamclient_a64.dll"
    local src=$PROTON/lsteamclient o=$OBJ/lsteamclient flags
    mkdir -p "$o"
    flags="$(wine_pe_flags "$src") -DSTEAM_API_EXPORTS -Dprivate=public -Dprotected=public"
    for f in "$src"/*.c; do
        echo "$CC -c $flags '$f' -o '$o/$(basename "$f").o'"
    done | xargs -P"$JOBS" -I{} sh -c '{}'
    # shellcheck disable=SC2086
    $CC -c $flags -D__WINE_PE_BUILD "$WINE/dlls/winecrt0/unix_lib.c" -o "$o/unix_lib.o"
    { echo "LIBRARY lsteamclient_a64.dll"; echo EXPORTS
      grep -E '^[0-9@]+ +cdecl' "$src/lsteamclient.spec" | sed -E 's/^[0-9@]+ +cdecl +(-private +)?([A-Za-z0-9_]+).*/\2/'
    } > "$OBJ/lsteamclient.def"
    wine_import_lib ntdll "$OBJ/libntdll_wine.a"
    $CC -shared -o "$OUT/lsteamclient_a64.dll" "$o"/*.o "$OBJ/lsteamclient.def" \
        -L"$OBJ" -lntdll_wine -luser32 -lws2_32
    mark_wine_builtin "$OUT/lsteamclient_a64.dll"
}

step_wineopenxr() {
    log "wineopenxr_a64.dll"
    local src=$PROTON/wineopenxr o=$OBJ/wineopenxr flags
    mkdir -p "$o"
    flags="$(wine_pe_flags "$src") -DWINE_NO_LONG_TYPES"
    for f in openxr_loader.c loader_thunks.c; do
        # shellcheck disable=SC2086
        $CC -c $flags "$src/$f" -o "$o/$f.o"
    done
    # shellcheck disable=SC2086
    $CC -c $flags -D__WINE_PE_BUILD "$WINE/dlls/winecrt0/unix_lib.c" -o "$o/unix_lib.o"
    printf 'LIBRARY wineopenxr_a64.dll\nEXPORTS\nxrNegotiateLoaderRuntimeInterface\n__wineopenxr_GetVulkanInstanceExtensions\n__wineopenxr_GetVulkanDeviceExtensions\nwineopenxr_init_registry\n' \
        > "$OBJ/wineopenxr.def"
    wine_import_lib ntdll "$OBJ/libntdll_wine.a"
    wine_import_lib winevulkan "$OBJ/libwinevulkan_wine.a"
    $CC -shared -o "$OUT/wineopenxr_a64.dll" "$o"/*.o "$OBJ/wineopenxr.def" \
        -L"$OBJ" -lwinevulkan_wine -lntdll_wine -ldxgi -ladvapi32 -luser32
    mark_wine_builtin "$OUT/wineopenxr_a64.dll"
}

step_steam_api() {
    log "steam_api64.dll"
    local src=$ROOT/src/steam-api o=$OBJ/steam-api sdk=$PROTON/lsteamclient/steamworks_sdk_161
    mkdir -p "$o/inc"
    ln -sfn "$sdk" "$o/inc/steam"
    python3 "$src/gen.py" "$PROTON/lsteamclient" "$o"
    python3 "$src/gen_sdk_inline.py" "$sdk/steamnetworkingtypes.h" "$o/sdk_inline_impl.inc"
    local flags=(-O2 -I"$o/inc" -I"$src" -I"$o" -Wall -Wno-unused-parameter -Wno-unused-function -Wno-pragma-pack -Wno-unknown-pragmas)
    $CXX -c "${flags[@]}" "$o/flat_generated.cpp" -o "$o/flat_generated.o"
    $CXX -c "${flags[@]}" "$src/steam_api_core.cpp" -o "$o/steam_api_core.o"
    $CXX -c "${flags[@]}" "$src/steam_api_helpers.cpp" -o "$o/steam_api_helpers.o"
    $CXX -shared -O2 -static -o "$OUT/steam_api64.dll" "$o"/flat_generated.o "$o"/steam_api_core.o "$o"/steam_api_helpers.o
}

step_openxr_loader() {
    log "openxr_loader.dll"
    local src=$DEPS/OpenXR-SDK b=$OBJ/openxr-loader
    git -C "$src" apply --check "$ROOT/patches/openxr-loader/"*.patch 2>/dev/null && git -C "$src" apply "$ROOT/patches/openxr-loader/"*.patch
    mkdir -p "$b"
    cat > "$b/toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR ARM64)
set(CMAKE_C_COMPILER $CC)
set(CMAKE_CXX_COMPILER $CXX)
set(CMAKE_RC_COMPILER $TC/bin/aarch64-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH $TC/aarch64-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF
    cmake -S "$src" -B "$b" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$b/toolchain.cmake" -DCMAKE_BUILD_TYPE=Release \
        -DDYNAMIC_LOADER=ON -DBUILD_TESTS=OFF -DBUILD_API_LAYERS=OFF -DBUILD_CONFORMANCE_TESTS=OFF >/dev/null
    ninja -C "$b" openxr_loader >/dev/null
    cp "$b/src/loader/openxr_loader.dll" "$OUT/"
}

step_dxvk() {
    log "DXVK (dxgi.dll, d3d11.dll)"
    local src=$DEPS/dxvk b=$OBJ/dxvk
    git -C "$src" apply --check "$ROOT/patches/dxvk/0001-libcxx-missing-includes.patch" 2>/dev/null &&
        git -C "$src" apply "$ROOT/patches/dxvk/0001-libcxx-missing-includes.patch"
    git -C "$src/subprojects/dxbc-spirv" apply --check "$ROOT/patches/dxvk/0002-dxbc-spirv-missing-include.patch" 2>/dev/null &&
        git -C "$src/subprojects/dxbc-spirv" apply "$ROOT/patches/dxvk/0002-dxbc-spirv-missing-include.patch"
    cat > "$OBJ/dxvk-cross-aarch64.txt" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$TC/bin/aarch64-w64-mingw32-ar'
strip = '$TC/bin/aarch64-w64-mingw32-strip'
windres = '$TC/bin/aarch64-w64-mingw32-windres'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
    [ -f "$b/build.ninja" ] || meson setup --cross-file "$OBJ/dxvk-cross-aarch64.txt" --buildtype release -Dbuild_id=false "$b" "$src" >/dev/null
    ninja -C "$b" >/dev/null
    cp "$b/src/dxgi/dxgi.dll" "$b/src/d3d11/d3d11.dll" "$OUT/"
}

step_monoposixhelper() {
    log "MonoPosixHelper.dll"
    local z=$DEPS/zlib-$ZLIB_VERSION
    $CC -O2 -shared -o "$OUT/MonoPosixHelper.dll" -I"$ROOT/src/monoposixhelper" -I"$z" -DHAVE_SYS_ZLIB \
        "$DEPS/zlib-helper.c" "$z"/{adler32,crc32,deflate,inflate,inffast,inftrees,trees,zutil}.c
}

ALL=(toolchain fetch wine-tools lsteamclient wineopenxr steam-api openxr-loader dxvk monoposixhelper)
STEPS=("$@")
[ ${#STEPS[@]} -eq 0 ] && STEPS=("${ALL[@]}")
for s in "${STEPS[@]}"; do
    "step_${s//-/_}"
done
cp "$ROOT/src/unityopenxr/patch_unityopenxr.py" "$ROOT/tools/unity_pkg_extract.py" "$ROOT/tools/vcredist_extract.py" "$OUT/"
log "done"
ls -la "$OUT"
