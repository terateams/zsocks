#!/usr/bin/env python3
"""Local benchmark for zsocks: relay throughput + connection rate."""
import socket, struct, threading, time, sys, argparse, statistics

class Backend(threading.Thread):
    def __init__(self, host='127.0.0.1', port=0, payload=1 << 20):
        super().__init__(daemon=True)
        self.payload = payload
        self.buf = b'x' * (1 << 16)
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind((host, port))
        self.srv.listen(1024)
        self.addr = self.srv.getsockname()
        self.running = True

    def run(self):
        while self.running:
            try:
                c, _ = self.srv.accept()
            except OSError:
                break
            threading.Thread(target=self.handle, args=(c,), daemon=True).start()

    def handle(self, c):
        try:
            c.recv(16)
            remaining = self.payload
            while remaining > 0:
                chunk = self.buf if remaining >= len(self.buf) else self.buf[:remaining]
                c.sendall(chunk)
                remaining -= len(chunk)
        except OSError:
            pass
        finally:
            c.close()

    def stop(self):
        self.running = False
        try: self.srv.close()
        except OSError: pass

def socks_connect(proxy, dst_host, dst_port, user=None, pwd=None):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(proxy)
    if user:
        s.sendall(b'\x05\x01\x02'); assert s.recv(2) == b'\x05\x02'
        s.sendall(bytes([1, len(user)]) + user.encode() + bytes([len(pwd)]) + pwd.encode())
        assert s.recv(2) == b'\x01\x00'
    else:
        s.sendall(b'\x05\x01\x00'); assert s.recv(2) == b'\x05\x00'
    s.sendall(b'\x05\x01\x00\x01' + socket.inet_aton(dst_host) + struct.pack('!H', dst_port))
    rep = s.recv(10); assert rep[1] == 0, f'socks reply {rep[1]}'
    return s

def direct_connect(_proxy, dst_host, dst_port, **_):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect((dst_host, dst_port))
    return s

def throughput(connect, proxy, backend, payload, conns, auth):
    results = []
    def worker():
        s = connect(proxy, backend[0], backend[1], **auth)
        s.sendall(b'g'); got = 0
        while got < payload:
            d = s.recv(1 << 16)
            if not d: break
            got += len(d)
        s.close(); results.append(got)
    ths = [threading.Thread(target=worker) for _ in range(conns)]
    t0 = time.perf_counter()
    for t in ths: t.start()
    for t in ths: t.join()
    return sum(results), time.perf_counter() - t0

def conn_rate(connect, proxy, backend, total, concurrency, auth):
    latencies = []; lock = threading.Lock(); counter = [0]
    def worker():
        while True:
            with lock:
                if counter[0] >= total: return
                counter[0] += 1
            t0 = time.perf_counter()
            try:
                s = connect(proxy, backend[0], backend[1], **auth)
                s.sendall(b'g'); s.recv(64); s.close()
            except Exception:
                continue
            with lock:
                latencies.append((time.perf_counter() - t0) * 1000)
    ths = [threading.Thread(target=worker) for _ in range(concurrency)]
    t0 = time.perf_counter()
    for t in ths: t.start()
    for t in ths: t.join()
    return latencies, time.perf_counter() - t0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--proxy-port', type=int, default=11080)
    ap.add_argument('--user'); ap.add_argument('--pass', dest='pwd')
    ap.add_argument('--payload-mb', type=int, default=256)
    ap.add_argument('--tput-conns', type=int, default=4)
    ap.add_argument('--rate-total', type=int, default=2000)
    ap.add_argument('--rate-conc', type=int, default=50)
    args = ap.parse_args()
    auth = {'user': args.user, 'pwd': args.pwd} if args.user else {}
    proxy = ('127.0.0.1', args.proxy_port); payload = args.payload_mb << 20

    be = Backend(payload=payload); be.start(); time.sleep(0.2)
    print(f'== throughput: {args.tput_conns} parallel conn x {args.payload_mb} MB ==')
    for label, conn in (('direct (baseline)', direct_connect), ('via zsocks', socks_connect)):
        a = auth if conn is socks_connect else {}
        total, wall = throughput(conn, proxy, be.addr, payload, args.tput_conns, a)
        mb = total / (1 << 20)
        print(f'  {label:18s} {mb:8.1f} MB  {wall:6.2f}s  => {mb/wall:8.1f} MB/s ({mb*8/wall:8.0f} Mbps)')
    be.stop(); time.sleep(0.1)

    be2 = Backend(payload=64); be2.start(); time.sleep(0.2)
    print(f'== conn-rate: {args.rate_total} conns, concurrency {args.rate_conc} ==')
    for label, conn in (('direct (baseline)', direct_connect), ('via zsocks', socks_connect)):
        a = auth if conn is socks_connect else {}
        lat, wall = conn_rate(conn, proxy, be2.addr, args.rate_total, args.rate_conc, a)
        if not lat:
            print(f'  {label:18s} no successful connections'); continue
        lat.sort(); p50 = statistics.median(lat); p99 = lat[min(len(lat)-1, int(len(lat)*0.99))]
        print(f'  {label:18s} {len(lat):5d} ok  {wall:5.2f}s  => {len(lat)/wall:8.0f} conn/s  '
              f'p50={p50:6.2f}ms p99={p99:6.2f}ms')
    be2.stop()

if __name__ == '__main__':
    main()
