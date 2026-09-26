#!/usr/bin/env python3
"""Stream-extract files from a Unity macOS target-support .pkg (xar archive whose
'Payload' is a gzip-compressed odc cpio archive), using only the Python stdlib.

Only the requested paths are written, so the ~500 MB package never has to be stored.

usage: unity_pkg_extract.py <url-or-file> <out-dir> <path-prefix> [<path-prefix> ...]
  path prefixes are matched against the cpio member names without a leading './'
"""
import os
import struct
import sys
import urllib.request
import xml.etree.ElementTree as ET
import zlib

CHUNK = 1 << 20


def open_source(src):
    if src.startswith(('http://', 'https://')):
        return urllib.request.urlopen(src)
    return open(src, 'rb')


class Reader:
    """Sequential reader that can skip forward."""

    def __init__(self, f):
        self.f = f
        self.pos = 0

    def read(self, n):
        data = b''
        while len(data) < n:
            chunk = self.f.read(min(CHUNK, n - len(data)))
            if not chunk:
                break
            data += chunk
        self.pos += len(data)
        return data

    def skip_to(self, pos):
        if pos < self.pos:
            raise ValueError('cannot seek backwards in stream')
        while self.pos < pos:
            if not self.read(min(CHUNK, pos - self.pos)):
                raise EOFError('unexpected end of xar archive')


def find_payload(toc_xml):
    root = ET.fromstring(toc_xml)
    for f in root.iter('file'):
        name = f.findtext('name')
        if name in ('Payload', 'Payload~'):
            data = f.find('data')
            encoding = data.find('encoding').get('style')
            return int(data.findtext('offset')), int(data.findtext('length')), encoding
    raise ValueError('no Payload in pkg')


def cpio_members(stream):
    """Yield (name, mode, data-reader) for each member of an odc cpio stream."""
    buf = b''

    def need(n):
        nonlocal buf
        while len(buf) < n:
            chunk = next(stream, None)
            if chunk is None:
                raise EOFError('truncated cpio archive')
            buf += chunk

    while True:
        need(76)
        header = buf[:76]
        if header[:6] != b'070707':
            raise ValueError(f'bad cpio magic {header[:6]!r}')
        mode = int(header[18:24], 8)
        namesize = int(header[59:65], 8)
        filesize = int(header[65:76], 8)
        need(76 + namesize)
        name = buf[76:76 + namesize - 1].decode('utf-8', 'replace')
        buf = buf[76 + namesize:]
        if name == 'TRAILER!!!':
            return
        remaining = filesize

        def data_chunks():
            nonlocal buf, remaining
            while remaining:
                if not buf:
                    need(1)
                take = buf[:remaining]
                buf = buf[len(take):]
                remaining -= len(take)
                yield take

        yield name, mode, data_chunks
        for _ in data_chunks():  # drain unread data
            pass


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    src, out_dir, prefixes = sys.argv[1], sys.argv[2], sys.argv[3:]

    reader = Reader(open_source(src))
    magic, header_size, _version, toc_len, _toc_len_raw, _cksum = struct.unpack('>4sHHQQI', reader.read(28))
    if magic != b'xar!':
        sys.exit('not a xar archive')
    reader.read(header_size - 28)
    toc = zlib.decompress(reader.read(toc_len))
    heap_start = header_size + toc_len
    offset, length, encoding = find_payload(toc)
    reader.skip_to(heap_start + offset)
    # The xar entry is either compressed by xar itself or stored raw; Unity stores a
    # gzip-compressed cpio raw ('application/octet-stream'). Both inflate the same way.
    first = reader.read(2)
    if 'gzip' not in encoding and 'zlib' not in encoding and first != b'\x1f\x8b':
        sys.exit(f'unsupported payload encoding {encoding}')
    inflater = zlib.decompressobj(47)  # zlib or gzip header

    def payload_stream():
        yield inflater.decompress(first)
        left = length - len(first)
        while left:
            chunk = reader.read(min(CHUNK, left))
            if not chunk:
                raise EOFError('truncated payload')
            left -= len(chunk)
            data = inflater.decompress(chunk)
            if data:
                yield data
        tail = inflater.flush()
        if tail:
            yield tail

    wanted = [p.lstrip('./') for p in prefixes]
    extracted = 0
    for name, mode, data_chunks in cpio_members(payload_stream()):
        rel = name[2:] if name.startswith('./') else name
        if not any(rel.startswith(p) for p in wanted) or (mode & 0o170000) != 0o100000:
            continue
        dst = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'wb') as f:
            for chunk in data_chunks():
                f.write(chunk)
        extracted += 1
        print(rel)
    if not extracted:
        sys.exit('no matching files found')


if __name__ == '__main__':
    main()
