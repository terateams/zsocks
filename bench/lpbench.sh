#!/usr/bin/env bash
# lpbench.sh — drive *real* browser page loads through zsocks using Lightpanda.
#
# The Zig load generator (`zig build bench`) measures the proxy's raw relay path
# with a hand-rolled HTTP/TLS client. This tool complements it by driving a real
# headless browser (https://github.com/lightpanda-io/browser) through the proxy,
# so each request behaves like an actual page load: full TLS, JavaScript, and
# sub-resource fetches — the closest thing to real user traffic.
#
# Requests are drawn at random from a pool of public sites so no single origin
# rate-limits the run.
#
# Usage:
#   bench/lpbench.sh --proxy 127.0.0.1:1080 [options]
#
# Options:
#   --proxy <host:port>   SOCKS5 proxy (default 127.0.0.1:1080)
#   --user <u>            SOCKS5 username
#   --pass <p>            SOCKS5 password
#   --list <file>         URL pool file (default bench/sites.txt)
#   --requests <N>        number of page loads to perform (default 20)
#   --dump <mode>         lightpanda --dump mode: html|markdown (default html)
#   --insecure            disable TLS host verification in the browser
#   --install             download the Lightpanda nightly for this platform
#   --lightpanda <path>   explicit path to the lightpanda binary
#   -h, --help            show this help
#
# The lightpanda binary is located via, in order: --lightpanda, $LIGHTPANDA,
# ./bench/lightpanda, ./lightpanda, or `lightpanda` on PATH. Use --install to
# fetch the nightly build automatically.
set -euo pipefail

PROXY="127.0.0.1:1080"
USER=""
PASS=""
LIST=""
REQUESTS=20
DUMP="html"
INSECURE=0
INSTALL=0
LP=""

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_LIST="$here/sites.txt"

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --proxy) PROXY="$2"; shift 2;;
    --user) USER="$2"; shift 2;;
    --pass) PASS="$2"; shift 2;;
    --list) LIST="$2"; shift 2;;
    --requests|-n) REQUESTS="$2"; shift 2;;
    --dump) DUMP="$2"; shift 2;;
    --insecure) INSECURE=1; shift;;
    --install) INSTALL=1; shift;;
    --lightpanda) LP="$2"; shift 2;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

LIST="${LIST:-$DEFAULT_LIST}"
[ -f "$LIST" ] || die "site list not found: $LIST"

# ---- locate / install lightpanda ------------------------------------------
detect_asset() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os-$arch" in
    Linux-x86_64)  echo "lightpanda-x86_64-linux";;
    Linux-aarch64) echo "lightpanda-aarch64-linux";;
    Darwin-arm64)  echo "lightpanda-aarch64-macos";;
    Darwin-x86_64) echo "lightpanda-x86_64-macos";;
    *) die "no Lightpanda nightly for $os-$arch; build from source: https://github.com/lightpanda-io/browser";;
  esac
}

if [ -n "$LP" ]; then
  :
elif [ -n "${LIGHTPANDA:-}" ]; then
  LP="$LIGHTPANDA"
elif [ -x "$here/lightpanda" ]; then
  LP="$here/lightpanda"
elif [ -x "./lightpanda" ]; then
  LP="./lightpanda"
elif command -v lightpanda >/dev/null 2>&1; then
  LP="$(command -v lightpanda)"
fi

if [ -z "$LP" ] && [ "$INSTALL" -eq 1 ]; then
  asset="$(detect_asset)"
  url="https://github.com/lightpanda-io/browser/releases/download/nightly/$asset"
  LP="$here/lightpanda"
  echo "downloading $url"
  curl -fL -o "$LP" "$url"
  chmod +x "$LP"
fi

if [ -z "$LP" ] || [ ! -x "$LP" ]; then
  cat >&2 <<EOF
error: lightpanda binary not found.

Install it one of these ways, then re-run:
  * brew install lightpanda-io/browser/lightpanda
  * bench/lpbench.sh --install            # download nightly into bench/
  * download manually: https://github.com/lightpanda-io/browser/releases/tag/nightly
  * point at an existing binary: --lightpanda /path/to/lightpanda
EOF
  exit 1
fi

# ---- build the libcurl-style proxy URL ------------------------------------
# Lightpanda routes HTTP through libcurl, which accepts socks5h:// (remote DNS,
# matching zsocks' domain-ATYP behaviour) and embedded credentials.
if [ -n "$USER" ]; then
  PROXY_URL="socks5h://${USER}:${PASS}@${PROXY}"
  PROXY_SHOWN="socks5h://${USER}:***@${PROXY}"
else
  PROXY_URL="socks5h://${PROXY}"
  PROXY_SHOWN="$PROXY_URL"
fi

LP_ARGS=(--http-proxy "$PROXY_URL" --dump "$DUMP" --log-level error)
[ "$INSECURE" -eq 1 ] && LP_ARGS+=(--insecure-disable-tls-host-verification)

# ---- load the URL pool -----------------------------------------------------
URLS=()
while IFS= read -r line || [ -n "$line" ]; do
  # trim leading whitespace, then skip blanks and comments
  trimmed="${line#"${line%%[![:space:]]*}"}"
  [ -z "$trimmed" ] && continue
  case "$trimmed" in \#*) continue;; esac
  URLS+=("$trimmed")
done < "$LIST"
[ "${#URLS[@]}" -gt 0 ] || die "no URLs in $LIST"

export LIGHTPANDA_DISABLE_TELEMETRY=true

echo "lightpanda    : $("$LP" version 2>/dev/null | head -1 || echo "$LP")"
echo "proxy         : $PROXY_SHOWN"
echo "pool          : ${#URLS[@]} sites in $LIST"
echo "load          : $REQUESTS page loads (random order), dump=$DUMP"
echo "running ..."
echo

ok=0; fail=0; total_bytes=0; total_ms=0
LAT=()

now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time()*1000'; }

for ((i=0; i<REQUESTS; i++)); do
  url="${URLS[RANDOM % ${#URLS[@]}]}"
  start=$(now_ms)
  if out="$("$LP" fetch "${LP_ARGS[@]}" "$url" 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi
  end=$(now_ms)
  ms=$(( end - start ))
  total_ms=$(( total_ms + ms ))
  LAT+=("$ms")
  if [ "$rc" -eq 0 ]; then
    bytes=${#out}
    total_bytes=$(( total_bytes + bytes ))
    ok=$(( ok + 1 ))
    printf '  [%3d/%-3d] %6dms %8dB  %s\n' "$((i+1))" "$REQUESTS" "$ms" "$bytes" "$url"
  else
    fail=$(( fail + 1 ))
    printf '  [%3d/%-3d] %6dms   FAIL(rc=%d)  %s\n' "$((i+1))" "$REQUESTS" "$ms" "$rc" "$url"
  fi
done

# ---- summary ---------------------------------------------------------------
p() { # percentile from sorted LAT_SORTED; $1 = fraction*100
  local idx=$(( (${#LAT_SORTED[@]} - 1) * $1 / 100 ))
  echo "${LAT_SORTED[$idx]}"
}
LAT_SORTED=()
while IFS= read -r v; do LAT_SORTED+=("$v"); done < <(printf '%s\n' "${LAT[@]}" | sort -n)

mb=$(awk "BEGIN{printf \"%.2f\", $total_bytes/1048576}")
secs=$(awk "BEGIN{printf \"%.2f\", $total_ms/1000}")

echo
echo "================ lightpanda results ================"
printf 'page loads   : %d (%d ok, %d failed)\n' "$REQUESTS" "$ok" "$fail"
printf 'content      : %s MB (rendered HTML/markdown captured)\n' "$mb"
if [ "${#LAT_SORTED[@]}" -gt 0 ]; then
  last_idx=$(( ${#LAT_SORTED[@]} - 1 ))
  printf 'latency (ms) : p50=%s  p95=%s  p99=%s  max=%s\n' "$(p 50)" "$(p 95)" "$(p 99)" "${LAT_SORTED[$last_idx]}"
fi
echo "===================================================="
