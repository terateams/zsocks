#!/usr/bin/env bash
# Hermetic functional end-to-end test for zsocks.
#
# Spins up local backends (an HTTP server for TCP CONNECT and a UDP echo server
# for UDP ASSOCIATE), starts the proxy with auth enabled, and exercises the full
# SOCKS5 surface using only curl + python3 (no external network needed):
#   - TCP CONNECT with correct credentials  -> 200
#   - TCP CONNECT with wrong credentials     -> rejected
#   - UDP ASSOCIATE round-trip               -> echo returns payload
#   - bounded memory                         -> server RSS reported
#
# Usage: test/e2e.sh [path-to-zsocks-binary]
# If no binary is given it builds one with `zig build`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-}"
PORT=11080
PUSER=zuser
PPASS=zpass
HTTP_PORT=18080
UDP_PORT=18053
PIDS=()

log()  { printf '\033[1;34m[e2e]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

if [ -z "$BIN" ]; then
  log "building zsocks (ReleaseSafe)"
  ( cd "$ROOT" && zig build -Doptimize=ReleaseSafe >/dev/null )
  BIN="$ROOT/zig-out/bin/zsocks"
fi
[ -x "$BIN" ] || fail "binary not found/executable: $BIN"
log "using binary: $BIN"

# --- local HTTP backend (TCP CONNECT target) --------------------------------
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
PIDS+=($!)

# --- local UDP echo backend (UDP ASSOCIATE target) --------------------------
python3 -c '
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", int(sys.argv[1])))
while True:
    data, addr = s.recvfrom(65535)
    s.sendto(data, addr)
' "$UDP_PORT" >/dev/null 2>&1 &
PIDS+=($!)

# --- the proxy --------------------------------------------------------------
"$BIN" -l 127.0.0.1 -p "$PORT" --user "$PUSER" --pass "$PPASS" >/dev/null 2>&1 &
SRV=$!
PIDS+=($SRV)

sleep 1
kill -0 "$SRV" 2>/dev/null || fail "proxy did not start"

# --- 1. TCP CONNECT with correct credentials --------------------------------
log "TCP CONNECT (auth ok)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  --socks5-hostname "$PUSER:$PPASS@127.0.0.1:$PORT" "http://127.0.0.1:$HTTP_PORT/" || true)
[ "$code" = "200" ] && ok "got HTTP $code" || fail "expected 200, got '$code'"

# --- 2. TCP CONNECT with wrong credentials ----------------------------------
log "TCP CONNECT (auth wrong -> must be rejected)"
if curl -s -o /dev/null --max-time 10 \
  --socks5-hostname "$PUSER:wrongpw@127.0.0.1:$PORT" "http://127.0.0.1:$HTTP_PORT/" 2>/dev/null; then
  fail "proxy accepted wrong credentials"
else
  ok "wrong credentials rejected"
fi

# --- 3. UDP ASSOCIATE round-trip --------------------------------------------
log "UDP ASSOCIATE (echo round-trip)"
python3 - "$PORT" "$PUSER" "$PPASS" "$UDP_PORT" <<'PY' && ok "UDP echo round-trip ok" || fail "UDP relay failed"
import socket, struct, sys
proxy_port, user, pwd, udp_port = int(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
t = socket.socket(); t.settimeout(5); t.connect(("127.0.0.1", proxy_port))
t.sendall(b"\x05\x01\x02"); assert t.recv(2) == b"\x05\x02"
t.sendall(bytes([1, len(user)]) + user.encode() + bytes([len(pwd)]) + pwd.encode())
assert t.recv(2) == b"\x01\x00"
t.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
r = t.recv(10); assert r[1] == 0, r
relay_port = struct.unpack("!H", r[8:10])[0]
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(5)
payload = b"hello-zsocks-udp"
hdr = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", udp_port)
u.sendto(hdr + payload, ("127.0.0.1", relay_port))
data, _ = u.recvfrom(2048)
echoed = data[10:]  # strip 10-byte ipv4 SOCKS UDP header
assert echoed == payload, (echoed, payload)
PY

# --- 4. bounded memory ------------------------------------------------------
if rss=$(ps -o rss= -p "$SRV" 2>/dev/null); then
  mb=$(awk -v r="$rss" 'BEGIN{printf "%.1f", r/1024}')
  log "server RSS: ${mb} MB"
fi

log "all checks passed"
