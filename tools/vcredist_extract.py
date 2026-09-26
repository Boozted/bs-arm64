#!/usr/bin/env python3
"""Extract the ARM64 VC++ runtime DLLs from Microsoft's vc_redist.arm64.exe.

The WiX bundle carries its payload as cabinets appended to the exe. We carve them out,
then let bsdtar (libarchive; ships with SteamOS) or cabextract unpack the LZX data.

usage: vcredist_extract.py <vc_redist.arm64.exe> <out-dir> <dll> [<dll> ...]
  e.g. vcredist_extract.py vc_redist.arm64.exe out vcruntime140.dll msvcp140.dll
"""
import os
import shutil
import struct
import subprocess
import sys
import tempfile


def carve_cabinets(data):
    i = 0
    while True:
        i = data.find(b'MSCF\0\0\0\0', i)
        if i < 0:
            return
        size = struct.unpack_from('<I', data, i + 8)[0]
        if 0 < size <= len(data) - i:
            yield data[i:i + size]
        i += 4


def unpack(archive, dest, members=()):
    if shutil.which('bsdtar'):
        cmd = ['bsdtar', '-x', '-f', archive, '-C', dest, *members]
    elif shutil.which('cabextract'):
        cmd = ['cabextract', '-q', '-d', dest, archive] + [a for m in members for a in ('-F', m)]
    else:
        sys.exit('need bsdtar (libarchive) or cabextract')
    subprocess.run(cmd, check=True)


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    exe, out_dir, dlls = sys.argv[1], sys.argv[2], sys.argv[3:]
    os.makedirs(out_dir, exist_ok=True)
    data = open(exe, 'rb').read()
    with tempfile.TemporaryDirectory() as tmp:
        for n, cab in enumerate(carve_cabinets(data)):
            path = os.path.join(tmp, f'outer{n}.cab')
            open(path, 'wb').write(cab)
            try:
                unpack(path, tmp)
            except subprocess.CalledProcessError:
                continue
        # The runtime DLLs live in an inner cabinet as '<name>_arm64'.
        wanted = [f'{d}_arm64' for d in dlls]
        for name in sorted(os.listdir(tmp)):
            path = os.path.join(tmp, name)
            if name.startswith('outer') or not os.path.isfile(path) or open(path, 'rb').read(4) != b'MSCF':
                continue
            try:
                unpack(path, tmp, wanted)
            except subprocess.CalledProcessError:
                continue
        missing = []
        for dll, member in zip(dlls, wanted):
            src = os.path.join(tmp, member)
            if os.path.exists(src):
                shutil.copy(src, os.path.join(out_dir, dll))
                print(dll)
            else:
                missing.append(dll)
        if missing:
            sys.exit(f'not found in redistributable: {", ".join(missing)}')


if __name__ == '__main__':
    main()
