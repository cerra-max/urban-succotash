#!/usr/bin/env python3
"""无边记 · 多人协作服务器（只用 Python 标准库）

    python3 server.py [--port 8787] [--host 0.0.0.0] [--data ./collab-data]

端口也可以用环境变量 PORT 指定（Render 等云平台会自动设置）。
免费云主机的磁盘通常不持久，重启后房间可能变空：这时第一个带着本地副本重连的人会把画板重新上传。

- GET /              提供 index.html（局域网内其他人可直接用浏览器打开）
- GET /api/info      服务器信息（局域网地址，用于生成分享链接）
- WS  /ws?room=ID    协作通道

同步模型：画板 = items（按 id 存放的元素）+ order（顶层元素顺序）+ assets（图片）。
客户端把本地修改整理成按元素的差异（op）发给服务器，服务器按到达顺序应用（同一元素后写者胜），
修复思维导图父子关系后广播给房间里的其他人。服务器上的房间状态即权威状态，定期写入磁盘。
"""
import argparse, asyncio, base64, hashlib, json, os, random, re, socket, struct, time
from urllib.parse import urlparse, parse_qs

ROOT = os.path.dirname(os.path.abspath(__file__))
GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
ROOM_RE = re.compile(r'^[A-Za-z0-9_-]{4,40}$')
MAX_MSG = 64 * 1024 * 1024
COLORS = ['#F25C54', '#F79D3B', '#43AA8B', '#3D8BE9', '#7B61FF', '#E05C9F', '#0FA3B1', '#B5838D']


# ============ WebSocket ============
class WS:
    def __init__(self, reader, writer):
        self.r, self.w = reader, writer
        self.closed = False
        self.lock = asyncio.Lock()

    async def recv(self):
        """返回一条文本消息；连接关闭时返回 None"""
        buf, opcode = b'', None
        while True:
            h = await self.r.readexactly(2)
            fin, op = h[0] & 0x80, h[0] & 0x0F
            masked, n = h[1] & 0x80, h[1] & 0x7F
            if n == 126: n = struct.unpack('!H', await self.r.readexactly(2))[0]
            elif n == 127: n = struct.unpack('!Q', await self.r.readexactly(8))[0]
            if n + len(buf) > MAX_MSG: raise ValueError('消息过大')
            mask = await self.r.readexactly(4) if masked else None
            data = await self.r.readexactly(n)
            if mask: data = _unmask(data, mask)
            if op == 0x8: return None
            if op == 0x9: await self._send(0xA, data); continue
            if op == 0xA: continue
            if op in (0x1, 0x2): opcode, buf = op, data
            elif op == 0x0: buf += data
            if fin and opcode is not None: return buf.decode('utf-8')

    async def send(self, text):
        await self._send(0x1, text.encode('utf-8'))

    async def _send(self, op, data):
        if self.closed: return
        n = len(data)
        head = bytes([0x80 | op]) + (bytes([n]) if n < 126 else bytes([126]) + struct.pack('!H', n) if n < 65536 else bytes([127]) + struct.pack('!Q', n))
        async with self.lock:
            try:
                self.w.write(head + data)
                await self.w.drain()
            except (ConnectionError, RuntimeError):
                self.closed = True

    def close(self):
        self.closed = True
        try: self.w.close()
        except Exception: pass


def _unmask(data, mask):
    if not data: return data
    m = int.from_bytes((mask * (len(data) // 4 + 1))[:len(data)], 'big')
    return (int.from_bytes(data, 'big') ^ m).to_bytes(len(data), 'big')


# ============ 房间 ============
class Room:
    def __init__(self, rid, path):
        self.id, self.path = rid, path
        self.items, self.order, self.assets, self.name = {}, [], {}, '协作画板'
        self.seq = 0
        self.peers = {}          # pid -> Peer
        self.dirty = False
        if os.path.exists(path):
            try:
                with open(path, encoding='utf-8') as fp: d = json.load(fp)
                self.items, self.order = d.get('items') or {}, d.get('order') or []
                self.assets, self.name, self.seq = d.get('assets') or {}, d.get('name') or self.name, d.get('seq') or 0
            except Exception as e:
                print('读取房间失败', rid, e)

    def empty(self):
        return not self.items and self.seq == 0

    def snapshot(self):
        return {'items': self.items, 'order': self.order, 'assets': self.assets, 'name': self.name, 'seq': self.seq}

    def save(self):
        if not self.dirty: return
        self.dirty = False
        tmp = self.path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as fp: json.dump(self.snapshot(), fp, ensure_ascii=False)
        os.replace(tmp, self.path)

    def apply(self, op):
        """应用客户端的修改，返回 (广播给其他人的修改, 需要回传给发送者的修正)"""
        out = {}
        items = op.get('items') or {}
        for k, v in items.items():
            if not isinstance(k, str): continue
            if v is None: self.items.pop(k, None)
            elif isinstance(v, dict): self.items[k] = v
            else: continue
        changed = set(items)
        if items: out['items'] = dict(items)
        if isinstance(op.get('assets'), dict):
            out['assets'] = {k: v for k, v in op['assets'].items() if isinstance(v, str)}
            self.assets.update(out['assets'])
        if isinstance(op.get('name'), str):
            self.name = out['name'] = op['name'][:200]
        if isinstance(op.get('order'), list):
            # 以客户端给出的顺序为准，同时保留别人刚添加、而这个客户端还不知道的元素
            inc = [i for i in op['order'] if isinstance(i, str)]
            s = set(inc)
            self.order = inc + [i for i in self.order if i not in s and i not in changed]
        fixed = self.repair()
        fix = {}
        if fixed:
            fix['items'] = {k: self.items.get(k) for k in fixed}
            out.setdefault('items', {}).update(fix['items'])
        old = self.order
        self.order = list(dict.fromkeys(i for i in self.order if i in self.items))
        if 'order' in op or self.order != old: out['order'] = self.order
        if out.get('order') is not None and out['order'] != op.get('order'): fix['order'] = self.order
        if out:
            self.seq += 1
            self.dirty = True
        return out, fix

    def repair(self):
        """并发修改可能破坏思维导图父子关系，在这里修复"""
        fixed = set()
        for _ in range(3):
            again = False
            for k, n in list(self.items.items()):
                if n.get('type') != 'mind': continue
                p = n.get('parent')
                if p:
                    pn = self.items.get(p)
                    if not pn or pn.get('type') != 'mind':
                        del self.items[k]; fixed.add(k); again = True; continue   # 父主题已被删除
                    if k not in (pn.get('children') or []):
                        pn['children'] = (pn.get('children') or []) + [k]; fixed.add(p)
                ch = n.get('children') or []
                good = [c for c in dict.fromkeys(ch) if c in self.items and self.items[c].get('parent') == k]
                if good != ch: n['children'] = good; fixed.add(k)
            if not again: break
        # 顶层主题必须在 order 中
        s = set(self.order)
        for k, n in self.items.items():
            if n.get('type') == 'mind' and not n.get('parent') and k not in s: self.order.append(k)
        return fixed

    async def broadcast(self, msg, skip=None):
        text = json.dumps(msg, ensure_ascii=False)
        await asyncio.gather(*(p.ws.send(text) for pid, p in list(self.peers.items()) if pid != skip))


class Peer:
    def __init__(self, ws, pid, name, color):
        self.ws, self.id, self.name, self.color = ws, pid, name, color
        self.presence = {}

    def info(self):
        return {'id': self.id, 'name': self.name, 'color': self.color, **self.presence}


rooms = {}


def get_room(rid):
    if rid not in rooms:
        rooms[rid] = Room(rid, os.path.join(DATA, rid + '.json'))
    return rooms[rid]


async def handle_ws(ws, query):
    rid = (query.get('room') or [''])[0]
    if not ROOM_RE.match(rid):
        await ws.send(json.dumps({'type': 'error', 'message': '无效的房间号'})); return
    room = get_room(rid)
    pid = os.urandom(4).hex()
    used = {p.color for p in room.peers.values()}
    color = next((c for c in COLORS if c not in used), random.choice(COLORS))
    name = ((query.get('name') or [''])[0] or '访客')[:24]
    peer = Peer(ws, pid, name, color)
    room.peers[pid] = peer
    print(f'[{rid}] {name} 加入（{len(room.peers)} 人在线）')
    try:
        await ws.send(json.dumps({'type': 'welcome', 'you': peer.info(), 'peers': [p.info() for p in room.peers.values() if p is not peer],
                                  'doc': room.snapshot(), 'fresh': room.empty()}, ensure_ascii=False))
        await room.broadcast({'type': 'join', 'peer': peer.info()}, skip=pid)
        while True:
            text = await ws.recv()
            if text is None: break
            try: m = json.loads(text)
            except ValueError: continue
            t = m.get('type')
            if t == 'op':
                out, fix = room.apply(m.get('op') or {})
                await ws.send(json.dumps({'type': 'ack', 'id': m.get('id'), 'seq': room.seq, 'fix': fix or None}, ensure_ascii=False))
                if out: await room.broadcast({'type': 'op', 'from': pid, 'seq': room.seq, 'op': out}, skip=pid)
            elif t == 'presence':
                peer.presence = {k: m.get(k) for k in ('cursor', 'sel', 'editing')}
                await room.broadcast({'type': 'presence', 'id': pid, **peer.presence}, skip=pid)
            elif t == 'rename':
                peer.name = str(m.get('name') or '访客')[:24]
                await room.broadcast({'type': 'join', 'peer': peer.info()}, skip=pid)
            elif t == 'ping':
                await ws.send('{"type":"pong"}')
    except (asyncio.IncompleteReadError, ConnectionError, ValueError, UnicodeDecodeError):
        pass
    finally:
        room.peers.pop(pid, None)
        ws.close()
        print(f'[{rid}] {name} 离开（{len(room.peers)} 人在线）')
        await room.broadcast({'type': 'leave', 'id': pid})
        if not room.peers:
            room.save(); rooms.pop(rid, None)


# ============ HTTP ============
def lan_addrs():
    out = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('10.255.255.255', 1)); out.append(s.getsockname()[0]); s.close()
    except OSError: pass
    try:
        for a in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = a[4][0]
            if not ip.startswith('127.') and ip not in out: out.append(ip)
    except OSError: pass
    return out


async def respond(writer, status, body=b'', ctype='text/plain; charset=utf-8', extra=''):
    if isinstance(body, str): body = body.encode('utf-8')
    writer.write(f'HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {len(body)}\r\n'
                 f'Cache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n{extra}\r\n'.encode() + body)
    await writer.drain()


async def handle(reader, writer):
    try:
        head = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 30)
        lines = head.decode('latin-1').split('\r\n')
        method, target, _ = (lines[0].split(' ') + ['', ''])[:3]
        hdr = {}
        for ln in lines[1:]:
            if ':' in ln:
                k, v = ln.split(':', 1); hdr[k.strip().lower()] = v.strip()
        u = urlparse(target)
        if u.path == '/ws' and hdr.get('upgrade', '').lower() == 'websocket':
            key = hdr.get('sec-websocket-key', '')
            acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
            writer.write(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
                          f'Sec-WebSocket-Accept: {acc}\r\n\r\n').encode())
            await writer.drain()
            sock = writer.get_extra_info('socket')
            if sock: sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            await handle_ws(WS(reader, writer), parse_qs(u.query))
            return
        if method not in ('GET', 'HEAD'):
            return await respond(writer, '405 Method Not Allowed', '不支持的请求')
        if u.path in ('/', '/index.html'):
            with open(os.path.join(ROOT, 'index.html'), 'rb') as fp:
                return await respond(writer, '200 OK', fp.read(), 'text/html; charset=utf-8')
        if u.path == '/api/info':
            return await respond(writer, '200 OK', json.dumps({'app': 'wubianji', 'port': PORT, 'addrs': lan_addrs()}), 'application/json')
        await respond(writer, '404 Not Found', '找不到页面')
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, ConnectionError):
        pass
    finally:
        try: writer.close()
        except Exception: pass


async def autosave():
    while True:
        await asyncio.sleep(2)
        for r in list(rooms.values()):
            try: r.save()
            except Exception as e: print('保存失败', r.id, e)


async def main(host, port):
    server = await asyncio.start_server(handle, host, port, limit=MAX_MSG)
    asyncio.create_task(autosave())
    print(f'无边记协作服务器已启动，数据目录：{DATA}')
    print(f'  本机：  http://localhost:{port}/')
    for ip in lan_addrs(): print(f'  局域网：http://{ip}:{port}/')
    async with server: await server.serve_forever()


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description='无边记多人协作服务器')
    ap.add_argument('--host', default='0.0.0.0')
    ap.add_argument('--port', type=int, default=int(os.environ.get('PORT') or 8787))
    ap.add_argument('--data', default=os.path.join(ROOT, 'collab-data'))
    a = ap.parse_args()
    PORT, DATA = a.port, os.path.abspath(a.data)
    os.makedirs(DATA, exist_ok=True)
    try: asyncio.run(main(a.host, a.port))
    except KeyboardInterrupt:
        for r in rooms.values(): r.save()
        print('\n已停止')
