#!/usr/bin/env python3
"""Generate independent archive fixtures using Python and macOS bsdtar."""

import bz2
import gzip
import io
import lzma
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import zipfile
import zlib


def preview_image():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    width, height = 320, 200
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            if abs(x - width // 2) < 6 or abs(y - height // 2) < 6:
                color = (246, 167, 44)
            else:
                color = (45, 122, 172) if (x // 40 + y // 40) % 2 else (32, 75, 113)
            pixels.extend(color)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


def rar_stored(files):
    def block(kind, flags, body):
        header = struct.pack("<BHH", kind, flags, 7 + len(body)) + body
        return struct.pack("<H", zlib.crc32(header) & 0xFFFF) + header

    data = b"Rar!\x1a\x07\x00" + block(0x73, 0, b"\x00" * 6)
    for name, content in files.items():
        encoded = name.encode("ascii")
        body = struct.pack("<IIBIIBBHI", len(content), len(content), 3,
                           zlib.crc32(content), 0, 20, 0x30, len(encoded), 0o100644)
        data += block(0x74, 0x8000, body + encoded) + content
    return data + block(0x7B, 0, b"")


def main():
    root = Path(sys.argv[1]).resolve()
    root.mkdir(parents=True, exist_ok=True)
    source = root / "source"
    files = {
        "README.md": b"# Archive fixture\n\nRead only archive content.\n\n[Guide](docs/guide.md)\n\n![Pixel](images/pixel.png)\n",
        "docs/guide.md": b"# Archive guide\n\nA separate preview fixture.\n",
        "data.csv": b"Name,Value\nArchive,42\n",
        "images/pixel.png": preview_image(),
        "资料/说明.md": "# 压缩包说明\n\nUnicode filenames work.\n".encode(),
    }
    for name, content in files.items():
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)

    def zipped(name, entries):
        with zipfile.ZipFile(root / name, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path, content in entries:
                archive.writestr(path, content)

    zipped("example.zip", files.items())
    zipped("empty.zip", [])
    zipped("duplicate.zip", [("README.md", b"First"), ("readme.md", b"Second")])
    zipped("unicode-collision.zip", [("é.md", b"First"), ("e\u0301.md", b"Second")])
    zipped("conflict.zip", [("docs", b"File"), ("docs/readme.md", b"Child")])
    zipped("large.zip", [("large.txt", b"x" * 4096)])
    zipped("many.zip", [(f"file-{index}.txt", b"x") for index in range(8)])
    zipped("listing.zip", [(f"file-{index}.txt", b"x") for index in range(501)])
    zipped("deep.zip", [("/".join(["dir"] * 65) + "/file.md", b"Deep")])
    for name, path in {"traversal": "../escaped.md", "absolute": "/tmp/folio-archive-escaped.md",
                       "windows": "C:\\escaped.md", "backslash": "dir\\..\\escaped.md",
                       "control": "line\nbreak.md"}.items():
        zipped(name + ".zip", [(path, b"Unsafe")])
    zipped("html-name.zip", [("<img src=x onerror=alert(1)>.md", b"# Safe")])
    zipped("nested.zip", [("example.zip", (root / "example.zip").read_bytes())])

    archive_data = io.BytesIO()
    with tarfile.open(fileobj=archive_data, mode="w") as archive:
        for name, content in files.items():
            info = tarfile.TarInfo("./" + name)
            info.size = len(content)
            archive.addfile(info, io.BytesIO(content))
        directory = tarfile.TarInfo("./docs/")
        directory.type = tarfile.DIRTYPE
        archive.addfile(directory)
    tar = archive_data.getvalue()
    for suffix, content in {"tar": tar, "tar.gz": gzip.compress(tar), "tgz": gzip.compress(tar),
                            "tar.bz2": bz2.compress(tar), "tbz": bz2.compress(tar), "tbz2": bz2.compress(tar),
                            "tar.xz": lzma.compress(tar), "txz": lzma.compress(tar)}.items():
        (root / ("example." + suffix)).write_bytes(content)
    for suffix, compress in {"gz": gzip.compress, "bz2": bz2.compress, "xz": lzma.compress}.items():
        (root / ("notes.md." + suffix)).write_bytes(compress(files["README.md"]))

    with tarfile.open(root / "links.tar", "w") as archive:
        for name, kind, target in [("symbolic.md", tarfile.SYMTYPE, "/etc/hosts"),
                                   ("hard.md", tarfile.LNKTYPE, "README.md")]:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.linkname = target
            archive.addfile(info)
        content = b"Git metadata"
        info = tarfile.TarInfo(".git/config")
        info.size = len(content)
        archive.addfile(info, io.BytesIO(content))

    (root / "example.rar").write_bytes(rar_stored({"README.md": files["README.md"], "docs/guide.md": files["docs/guide.md"]}))
    subprocess.run(["/usr/bin/tar", "--format=7zip", "-cf", str(root / "example.7z"),
                    "-C", str(source), "."], check=True, env={"COPYFILE_DISABLE": "1", "PATH": "/usr/bin:/bin"})
    subprocess.run(["/usr/bin/zip", "-q", "-P", "fixture-password", str(root / "encrypted.zip"), "README.md"],
                   cwd=source, check=True)
    (root / "damaged.zip").write_bytes(b"PK\x03\x04broken archive")
    corrupted = bytearray((root / "example.zip").read_bytes())
    name_length, extra_length = struct.unpack_from("<HH", corrupted, 26)
    corrupted[30 + name_length + extra_length + 3] ^= 0xFF
    (root / "corrupt-data.zip").write_bytes(corrupted)
    (root / "fake.gz").write_bytes(b"Uncompressed text is not a gzip file.")
    print(f"Generated archive fixtures in {root}")


if __name__ == "__main__":
    main()
