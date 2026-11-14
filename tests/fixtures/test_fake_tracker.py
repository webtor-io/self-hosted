#!/usr/bin/env python3
"""Unit test for fake_tracker.py: stdlib only, no docker.

Builds a private torrent of a synthetic tree with make_fixture.build, runs
serve() in a daemon thread on free ports and talks to it as a client would.
Run: python3 tests/fixtures/test_fake_tracker.py
"""
import atexit
import hashlib
import json
import shutil
import socket
import struct
import sys
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fake_tracker import bdecode, serve  # noqa: E402
from make_fixture import PIECE_LENGTH, bencode, build  # noqa: E402

KEY = '0123456789abcdef0123456789abcdef'


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


tmp = Path(tempfile.mkdtemp())
atexit.register(shutil.rmtree, tmp, True)
root = tmp / 'content' / 'webtor-smoke-private'
(root / 'subs').mkdir(parents=True)
# 40000 bytes over a 32768 piece length: piece 0 is full and spans files
(root / 'video.mp4').write_bytes(bytes(range(256)) * 156 + b'x' * 64)
(root / 'readme.txt').write_bytes(b'hello\n')
(root / 'subs' / 'subtitle.srt').write_bytes(b'1\n00:00:00,000 --> 00:00:01,000\nhi\n')
torrent = tmp / 'p.torrent'
summary = build(root, '', torrent, private=True, announce=f'http://tracker.example:6969/announce/{KEY}')
info = bdecode(torrent.read_bytes())[b'info']
ih_bytes = hashlib.sha1(bencode(info)).digest()
pieces = info[b'pieces']
total = summary['total_length']

http_port, peer_port = free_port(), free_port()
threading.Thread(target=serve, args=(torrent, tmp / 'content', http_port, peer_port, '127.0.0.1'), daemon=True).start()
for _ in range(50):
    try:
        socket.create_connection(('127.0.0.1', peer_port)).close()
        urlopen(f'http://127.0.0.1:{http_port}/log').read()
        break
    except OSError:
        time.sleep(0.1)


def handshake_bytes(info_hash):
    return b'\x13BitTorrent protocol' + b'\0' * 8 + info_hash + b'-TT0000-000000000000'


def recv_exact(s, n):
    b = b''
    while len(b) < n:
        chunk = s.recv(n - len(b))
        assert chunk, 'peer closed the connection'
        b += chunk
    return b


def handshake(port, info_hash):
    s = socket.create_connection(('127.0.0.1', port), timeout=5)
    s.sendall(handshake_bytes(info_hash))
    reply = recv_exact(s, 68)
    assert reply[:20] == b'\x13BitTorrent protocol' and reply[20:28] == b'\0' * 8 and reply[28:48] == info_hash
    return s


def send_msg(s, mid, payload=b''):
    s.sendall(struct.pack('>IB', len(payload) + 1, mid) + payload)


def read_msg(s):
    while True:
        n = struct.unpack('>I', recv_exact(s, 4))[0]
        if n:  # skip keep-alives
            b = recv_exact(s, n)
            return b[0], b[1:]


def test_announce_records_key_and_returns_own_peer():
    q = urlencode({'info_hash': ih_bytes, 'peer_id': b'-AB0000-000000000000', 'port': 6881, 'event': 'started', 'compact': 1})
    reply = bdecode(urlopen(f'http://127.0.0.1:{http_port}/announce/{KEY}?{q}').read())
    assert reply[b'interval'] == 60
    assert reply[b'peers'] == socket.inet_aton('127.0.0.1') + struct.pack('>H', peer_port)
    log = json.load(urlopen(f'http://127.0.0.1:{http_port}/log'))
    assert log[-1] == {'key': KEY, 'info_hash': ih_bytes.hex(), 'peer_id': b'-AB0000-000000000000'.hex(), 'port': 6881, 'event': 'started'}


def test_peer_serves_piece_zero():
    s = handshake(peer_port, ih_bytes)
    mid, bitfield = read_msg(s)
    assert mid == 5 and bitfield[0] & 0x80, 'no bitfield with piece 0'
    send_msg(s, 2)  # interested
    assert read_msg(s)[0] == 1  # unchoke
    piece = b''
    while len(piece) < min(PIECE_LENGTH, total):
        send_msg(s, 6, struct.pack('>III', 0, len(piece), min(16384, min(PIECE_LENGTH, total) - len(piece))))
        mid, payload = read_msg(s)
        assert mid == 7 and payload[:8] == struct.pack('>II', 0, len(piece))
        piece += payload[8:]
    assert hashlib.sha1(piece).digest() == pieces[:20]


def test_peer_drops_foreign_infohash():
    s = socket.create_connection(('127.0.0.1', peer_port), timeout=5)
    s.sendall(handshake_bytes(b'\x01' * 20))
    assert s.recv(68) == b''


if __name__ == '__main__':
    for name, fn in list(globals().items()):
        if name.startswith('test_'):
            fn()
            print('PASS:', name)
