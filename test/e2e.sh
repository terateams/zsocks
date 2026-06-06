#!/usr/bin/env bash
# Hermetic functional end-to-end test for zsocks.
#
# Spins up local backends (HTTP servers on IPv4 and IPv6 loopback for TCP
# CONNECT plus a UDP echo server for UDP ASSOCIATE), starts two proxies (one
# with auth + UDP, one no-auth with --no-udp), and exercises the full SOCKS5
# surface using only curl + python3 (no external network needed):
#   - TCP CONNECT with correct credentials   -> 200
#   - TCP CONNECT with wrong credentials      -> rejected
#   - TCP CONNECT to a domain target (ATYP 3) -> 200
#   - TCP CONNECT to an IPv6 target (ATYP 4)  -> 200
#   - UDP ASSOCIATE round-trip                -> echo returns payload
#   - UDP ASSOCIATE under --no-udp            -> cmd_not_supported (0x07)
#   - BIND and unknown commands               -> cmd_not_supported (0x07)
#   - no acceptable auth method               -> 0xFF then close
#   - unsupported ATYP                        -> atyp_not_supported (0x08)
#   - bounded memory                          -> server RSS reported
#
# Usage: test/e2e.sh [path-to-zsocks-binary]
# If no binary is given it builds one with `zig build`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-}"
PORT=11080
NOUDP_PORT=11082
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
# IPv4 and IPv6 loopback share the same port (separate sockets per family) so a
# domain CONNECT to "localhost" reaches a backend regardless of which family it
# resolves to, and the IPv6 literal CONNECT has a target on [::1].
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
PIDS+=($!)
python3 -m http.server "$HTTP_PORT" --bind ::1 >/dev/null 2>&1 &
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

# A second, no-auth proxy with UDP disabled, to drive the command/UDP rejection
# paths with raw negotiation bytes.
"$BIN" -l 127.0.0.1 -p "$NOUDP_PORT" --no-udp >/dev/null 2>&1 &
NOUDP_SRV=$!
PIDS+=($NOUDP_SRV)

sleep 1
kill -0 "$SRV" 2>/dev/null || fail "proxy did not start"
kill -0 "$NOUDP_SRV" 2>/dev/null || fail "no-udp proxy did not start"

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

# --- 2b. TCP CONNECT to a domain target (ATYP 0x03) -------------------------
log "TCP CONNECT (domain target -> ATYP 0x03)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  --socks5-hostname "$PUSER:$PPASS@127.0.0.1:$PORT" "http://localhost:$HTTP_PORT/" || true)
[ "$code" = "200" ] && ok "domain CONNECT got HTTP $code" || fail "expected 200, got '$code'"

# --- 2c. TCP CONNECT to an IPv6 target (ATYP 0x04) --------------------------
log "TCP CONNECT (IPv6 target -> ATYP 0x04)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  --socks5 "$PUSER:$PPASS@127.0.0.1:$PORT" "http://[::1]:$HTTP_PORT/" || true)
[ "$code" = "200" ] && ok "IPv6 CONNECT got HTTP $code" || fail "expected 200, got '$code'"

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

# --- 4. command / method / ATYP rejection paths -----------------------------
# Driven with raw negotiation bytes against the no-auth, --no-udp proxy (and the
# auth proxy for the no-acceptable-method case).
log "rejection paths (raw negotiation)"
python3 - "$PORT" "$NOUDP_PORT" <<'PY' && ok "rejection paths ok" || fail "rejection paths failed"
import socket, sys
auth_port, noudp_port = int(sys.argv[1]), int(sys.argv[2])

def conn(port):
    s = socket.socket(); s.settimeout(5); s.connect(("127.0.0.1", port)); return s

def noauth(s):
    s.sendall(b"\x05\x01\x00")
    assert s.recv(2) == b"\x05\x00", "expected no-auth method selected"

# IPv4 127.0.0.1:80 request tail (ATYP + ADDR + PORT).
addr = b"\x01\x7f\x00\x00\x01\x00\x50"

# No acceptable method: the auth proxy wants username/password (0x02); offering
# only no-auth (0x00) must get 0xFF and a closed connection.
s = conn(auth_port)
s.sendall(b"\x05\x01\x00")
assert s.recv(2) == b"\x05\xff", "expected no-acceptable-method (0xFF)"
assert s.recv(1) == b"", "server should close after 0xFF"
s.close()

# BIND (CMD 0x02) -> cmd_not_supported (0x07).
s = conn(noudp_port); noauth(s)
s.sendall(b"\x05\x02\x00" + addr)
r = s.recv(10); assert r[1] == 0x07, ("BIND", r.hex())
s.close()

# Unknown command (0x09) -> cmd_not_supported (0x07).
s = conn(noudp_port); noauth(s)
s.sendall(b"\x05\x09\x00" + addr)
r = s.recv(10); assert r[1] == 0x07, ("cmd 0x09", r.hex())
s.close()

# UDP ASSOCIATE under --no-udp -> cmd_not_supported (0x07).
s = conn(noudp_port); noauth(s)
s.sendall(b"\x05\x03\x00" + addr)
r = s.recv(10); assert r[1] == 0x07, ("--no-udp UDP", r.hex())
s.close()

# Unsupported ATYP (0x05) -> atyp_not_supported (0x08).
s = conn(noudp_port); noauth(s)
s.sendall(b"\x05\x01\x00\x05")
r = s.recv(10); assert r[1] == 0x08, ("bad ATYP", r.hex())
s.close()
PY

# --- 5. bounded memory ------------------------------------------------------
if rss=$(ps -o rss= -p "$SRV" 2>/dev/null); then
  mb=$(awk -v r="$rss" 'BEGIN{printf "%.1f", r/1024}')
  log "server RSS: ${mb} MB"
fi

log "all checks passed"
