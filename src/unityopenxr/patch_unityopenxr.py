#!/usr/bin/env python3
"""Make Unity's UWP ARM64 UnityOpenXR.dll loadable in a desktop (Wine) process.

- MSVCP140_APP / VCRUNTIME140_APP -> desktop msvcp140 / vcruntime140
- LoadPackagedLibrary (stub in Wine, needs an app package) -> kernel32!LoadLibraryW
  (the extra 'reserved' argument is ignored under the ARM64 calling convention)

Only the Python standard library is used, so this runs on SteamOS as is.

usage: patch_unityopenxr.py <UWP arm64 UnityOpenXR.dll> <output dll>
"""
import struct
import sys

IMAGE_FILE_MACHINE_ARM64 = 0xAA64
IMPORT_DIRECTORY = 1
ORDINAL_FLAG64 = 1 << 63


class PE:
    def __init__(self, data):
        self.data = data
        pe = struct.unpack_from('<I', data, 0x3C)[0]
        if data[pe:pe + 4] != b'PE\0\0':
            raise ValueError('not a PE file')
        self.machine, nsections = struct.unpack_from('<HH', data, pe + 4)
        opt_size = struct.unpack_from('<H', data, pe + 20)[0]
        opt = pe + 24
        if struct.unpack_from('<H', data, opt)[0] != 0x20B:
            raise ValueError('not a PE32+ image')
        self.import_rva = struct.unpack_from('<I', data, opt + 112 + IMPORT_DIRECTORY * 8)[0]
        self.sections = []
        for i in range(nsections):
            s = opt + opt_size + i * 40
            vsize, va, rawsize, rawptr = struct.unpack_from('<IIII', data, s + 8)
            self.sections.append((va, max(vsize, rawsize), rawptr))

    def offset(self, rva):
        for va, size, raw in self.sections:
            if va <= rva < va + size:
                return rva - va + raw
        raise ValueError(f'RVA {rva:#x} outside all sections')

    def cstr(self, rva):
        off = self.offset(rva)
        return bytes(self.data[off:self.data.index(b'\0', off)])

    def imports(self):
        """Yield (descriptor name RVA, dll name, [(hint/name RVA, function name)])."""
        off = self.offset(self.import_rva)
        while True:
            oft, _ts, _fwd, name_rva, ft = struct.unpack_from('<IIIII', self.data, off)
            if not name_rva:
                return
            thunk = self.offset(oft or ft)
            funcs = []
            while True:
                entry = struct.unpack_from('<Q', self.data, thunk)[0]
                if not entry:
                    break
                if not entry & ORDINAL_FLAG64:
                    funcs.append((entry, self.cstr(entry + 2)))
                thunk += 8
            yield name_rva, self.cstr(name_rva), funcs
            off += 20


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    data = bytearray(open(sys.argv[1], 'rb').read())
    pe = PE(data)
    if pe.machine != IMAGE_FILE_MACHINE_ARM64:
        sys.exit(f'expected an ARM64 image, got machine {pe.machine:#x}')

    def overwrite(rva, old, new):
        off = pe.offset(rva)
        assert data[off:off + len(old)] == old and len(new) <= len(old)
        data[off:off + len(old)] = new.ljust(len(old), b'\0')

    renames = {b'MSVCP140_APP.dll': b'msvcp140.dll', b'VCRUNTIME140_APP.dll': b'vcruntime140.dll'}
    patched = set()
    for name_rva, dll, funcs in list(pe.imports()):
        if dll in renames:
            overwrite(name_rva, dll, renames[dll])
            patched.add(dll.decode())
        for hint_rva, func in funcs:
            if func == b'LoadPackagedLibrary':
                if len(funcs) != 1:
                    sys.exit('LoadPackagedLibrary shares its import descriptor; cannot redirect the DLL')
                overwrite(name_rva, dll, b'kernel32.dll')
                overwrite(hint_rva + 2, b'LoadPackagedLibrary', b'LoadLibraryW')
                patched.add('LoadPackagedLibrary')
    expected = {'MSVCP140_APP.dll', 'VCRUNTIME140_APP.dll', 'LoadPackagedLibrary'}
    if patched != expected:
        sys.exit(f'unexpected import layout; patched only {sorted(patched)}')
    open(sys.argv[2], 'wb').write(data)
    print('patched:', ', '.join(sorted(patched)))


if __name__ == '__main__':
    main()
