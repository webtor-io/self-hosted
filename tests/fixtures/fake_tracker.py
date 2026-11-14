#!/usr/bin/env python3
"""A private tracker and its only seeder, for the smoke suite. Stdlib only.

HTTP:
  GET /announce/<key>?info_hash=..&peer_id=..&port=..[&event=..]
      -> {"interval": 60, "peers": <this process's peer, compact>}, and the
         announce is logged: the passkey in the path is what the suite checks
         (only user A's key may ever reach the tracker).
  GET /log -> the announces so far, as a JSON array.
TCP <peer-port>: a plain (no MSE, no extensions) BitTorrent v1 seeder of the
one torrent given, read from <content>/<info name>/...: handshake, a full
bitfield, unchoke on interested, piece on request. A handshake for any other
infohash is closed without an answer.

Usage: fake_tracker.py --torrent PATH --content DIR [--http-port 6969]
                       [--peer-port 6881] [--peer-ip IP]
"""
import argparse
import hashlib
import json
import socket
import socketserver
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_fixture import bencode  # noqa: E402

PSTR = b"\x13BitTorrent protocol"


def bdecode(b: bytes) -> object:
    def at(i):
        c = b[i : i + 1]
        if c == b"i":
            e = b.index(b"e", i)
            return int(b[i + 1 : e]), e + 1
        if c == b"l":
            out, i = [], i + 1
            while b[i : i + 1] != b"e":
                v, i = at(i)
                out.append(v)
            return out, i + 1
        if c == b"d":
            out, i = {}, i + 1
            while b[i : i + 1] != b"e":
                k, i = at(i)
                out[k], i = at(i)
            return out, i + 1
        colon = b.index(b":", i)
        n = int(b[i:colon])
        return b[colon + 1 : colon + 1 + n], colon + 1 + n

    value, end = at(0)
    if end != len(b):
        raise ValueError("trailing bytes after bencoded value")
    return value


class Content:
    """The torrent's files, concatenated in info['files'] order."""

    def __init__(self, info: dict, root: Path):
        self.files = [(root.joinpath(*(p.decode() for p in f[b"path"])), f[b"length"]) for f in info[b"files"]]

    def read(self, offset: int, length: int) -> bytes:
        out = b""
        for path, size in self.files:
            if length <= 0:
                break
            if offset >= size:
                offset -= size
                continue
            with open(path, "rb") as f:
                f.seek(offset)
                chunk = f.read(min(length, size - offset))
            out += chunk
            length -= len(chunk)
            offset = 0
        return out


def recv_exact(sock, n):
    b = b""
    while len(b) < n:
        chunk = sock.recv(n - len(b))
        if not chunk:
            raise ConnectionError("peer closed")
        b += chunk
    return b


def serve(torrent: Path, content: Path, http_port: int, peer_port: int, peer_ip: str) -> None:
    info = bdecode(Path(torrent).read_bytes())[b"info"]
    info_hash = hashlib.sha1(bencode(info)).digest()
    data = Content(info, Path(content) / info[b"name"].decode())
    plen = info[b"piece length"]
    npieces = len(info[b"pieces"]) // 20
    bitfield = bytearray((npieces + 7) // 8)
    for i in range(npieces):
        bitfield[i // 8] |= 0x80 >> (i % 8)
    peer_id = b"-FT0001-" + hashlib.sha1(info_hash).digest()[:12]
    compact = socket.inet_aton(peer_ip) + struct.pack(">H", peer_port)
    log, lock = [], threading.Lock()

    class Tracker(BaseHTTPRequestHandler):
        def do_GET(self):
            u = urlsplit(self.path)
            if u.path == "/log":
                with lock:
                    return self.reply(200, "application/json", json.dumps(log).encode())
            if not u.path.startswith("/announce/"):
                return self.reply(404, "text/plain", b"not found")
            # latin-1 maps every byte to one code point and back: the raw
            # 20-byte info_hash and peer_id survive the query decoding.
            q = {k: v[0].encode("latin-1") for k, v in parse_qs(u.query, encoding="latin-1").items()}
            with lock:
                log.append(
                    {
                        "key": u.path[len("/announce/") :],
                        "info_hash": q.get("info_hash", b"").hex(),
                        "peer_id": q.get("peer_id", b"").hex(),
                        "port": int(q.get("port", b"0")),
                        "event": q.get("event", b"").decode(),
                    }
                )
            self.reply(200, "text/plain", bencode({b"interval": 60, b"peers": compact}))

        def reply(self, code, ctype, body):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    class Peer(socketserver.BaseRequestHandler):
        def handle(self):
            s = self.request
            try:
                hs = recv_exact(s, 68)
                if hs[:20] != PSTR or hs[28:48] != info_hash:
                    return  # an MSE handshake or another torrent: closed, no answer
                s.sendall(PSTR + b"\0" * 8 + info_hash + peer_id + struct.pack(">IB", len(bitfield) + 1, 5) + bitfield)
                while True:
                    n = struct.unpack(">I", recv_exact(s, 4))[0]
                    if n == 0:
                        continue  # keep-alive
                    msg = recv_exact(s, n)
                    if msg[0] == 2:  # interested
                        s.sendall(struct.pack(">IB", 1, 1))  # unchoke
                    elif msg[0] == 6:  # request
                        index, begin, length = struct.unpack(">III", msg[1:13])
                        block = data.read(index * plen + begin, length)
                        s.sendall(struct.pack(">IBII", 9 + len(block), 7, index, begin) + block)
            except (ConnectionError, OSError):
                pass

    class PeerServer(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    class HTTPServer(ThreadingHTTPServer):
        allow_reuse_address = True
        daemon_threads = True

    peers = PeerServer(("", peer_port), Peer)
    threading.Thread(target=peers.serve_forever, daemon=True).start()
    HTTPServer(("", http_port), Tracker).serve_forever()


def main():
    p = argparse.ArgumentParser(usage=__doc__)
    p.add_argument("--torrent", type=Path, required=True)
    p.add_argument("--content", type=Path, required=True)
    p.add_argument("--http-port", type=int, default=6969)
    p.add_argument("--peer-port", type=int, default=6881)
    p.add_argument("--peer-ip", default=None)
    a = p.parse_args()
    serve(a.torrent, a.content, a.http_port, a.peer_port, a.peer_ip or socket.gethostbyname(socket.gethostname()))


if __name__ == "__main__":
    main()
