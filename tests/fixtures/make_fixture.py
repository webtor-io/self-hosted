#!/usr/bin/env python3
"""Build a trackerless multi-file .torrent with a BEP19 webseed (url-list),
or with --private a BEP 27 private one: no webseed, optionally an announce URL.

Usage: make_fixture.py <content-dir> <webseed-url> <out.torrent> [--private] [--announce URL]
Prints a JSON summary of what was built.
"""
import argparse
import hashlib
import json
from pathlib import Path

PIECE_LENGTH = 32768


def bencode(value):
    if isinstance(value, bool):
        raise TypeError("bool is not bencodable")
    if isinstance(value, int):
        return b"i%de" % value
    if isinstance(value, str):
        return bencode(value.encode())
    if isinstance(value, bytes):
        return b"%d:%s" % (len(value), value)
    if isinstance(value, list):
        return b"l" + b"".join(bencode(v) for v in value) + b"e"
    if isinstance(value, dict):
        out = b"d"
        for key in sorted(value):
            out += bencode(key) + bencode(value[key])
        return out + b"e"
    raise TypeError("cannot bencode %r" % type(value))


def build(root: Path, webseed: str, out: Path, private: bool = False, announce: str | None = None) -> dict:
    # Sorted so piece hashing is deterministic for a given content tree.
    paths = sorted(p for p in root.rglob("*") if p.is_file())
    if not paths:
        raise SystemExit("no files under %s" % root)

    files = []
    pieces = b""
    buf = b""
    for path in paths:
        data = path.read_bytes()
        files.append(
            {
                b"length": len(data),
                b"path": [part.encode() for part in path.relative_to(root).parts],
            }
        )
        buf += data
        while len(buf) >= PIECE_LENGTH:
            pieces += hashlib.sha1(buf[:PIECE_LENGTH]).digest()
            buf = buf[PIECE_LENGTH:]
    if buf:
        pieces += hashlib.sha1(buf).digest()

    info = {
        b"name": root.name.encode(),
        b"piece length": PIECE_LENGTH,
        b"pieces": pieces,
        b"files": files,
    }
    if private:
        # Inside info, so it changes the infohash. No url-list: a private
        # torrent is fetched from its tracker's peers only (BEP 27).
        info[b"private"] = 1
        torrent = {b"info": info}
    else:
        # url-list as a list: both forms are legal, anacrolix accepts either.
        torrent = {b"info": info, b"url-list": [webseed.encode()]}
    if announce:
        torrent[b"announce"] = announce.encode()
    out.write_bytes(bencode(torrent))

    return {
        "name": root.name,
        "infohash": hashlib.sha1(bencode(info)).hexdigest(),
        "files": [
            {
                "path": "/".join(p.decode() for p in f[b"path"]),
                "length": f[b"length"],
            }
            for f in files
        ],
        "piece_length": PIECE_LENGTH,
        "pieces_count": len(pieces) // 20,
        "total_length": sum(f[b"length"] for f in files),
        "private": private,
    }


def main():
    p = argparse.ArgumentParser(usage=__doc__)
    p.add_argument("content_dir", type=Path)
    p.add_argument("webseed")
    p.add_argument("out", type=Path)
    p.add_argument("--private", action="store_true")
    p.add_argument("--announce")
    a = p.parse_args()
    print(json.dumps(build(a.content_dir, a.webseed, a.out, a.private, a.announce)))


if __name__ == "__main__":
    main()
