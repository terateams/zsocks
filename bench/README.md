# Benchmarks

Three complementary tools, from synthetic to fully realistic:

| Tool | Driver | Target | Measures |
|------|--------|--------|----------|
| `bench.py` | Python stdlib | in-process loopback server | raw relay overhead vs. direct baseline |
| `bench.zig` | Zig (`zig build bench`) | pool of **real public HTTPS sites** | end-to-end proxy throughput + latency over real TLS |
| `lpbench.sh` | [Lightpanda](https://github.com/lightpanda-io/browser) headless browser | pool of real sites | real page loads (full TLS + JS) through the proxy |

All three pick targets **randomly per request** from a shared pool so no single
origin rate-limits a run. The Zig and Lightpanda tools share
[`sites.txt`](./sites.txt).

Start a proxy first (ReleaseFast recommended for realistic numbers):

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/zsocks -l 127.0.0.1 -p 11080 --max-conns 512
```

---

## 1. `bench.py` — synthetic loopback (proxy overhead)

Spins up an in-process backend TCP data server and drives load both **directly**
(baseline) and **through the proxy**, isolating the relay overhead.

```sh
python3 bench/bench.py --proxy-port 11080 \
    --payload-mb 256 --tput-conns 8 \
    --rate-total 5000 --rate-conc 100
```

With auth:

```sh
zig-out/bin/zsocks -p 11080 --user u --pass p &
python3 bench/bench.py --proxy-port 11080 --user u --pass p
```

Measures:

- **throughput** — N parallel connections each downloading `--payload-mb`,
  reported as MB/s and Mbps (proxy vs. direct baseline).
- **conn-rate** — `--rate-total` short connections at `--rate-conc`
  concurrency, reported as conn/s with p50/p99 setup latency.

> Loopback numbers are dominated by memory-copy bandwidth and the Python client,
> so absolute figures are far higher than any real NIC. They are useful as a
> *relative* measure of proxy overhead and for confirming memory stays bounded.

---

## 2. `bench.zig` — real-internet load generator (zero deps)

A Zig load generator that drives real HTTPS requests through the proxy against a
random pool of public sites. It does a full SOCKS5 handshake (auth optional),
sends the target as a domain (so **the proxy resolves DNS**), runs TLS over the
tunnel with Zig's std client, and frames the HTTP response properly
(Content-Length / chunked / close-delimited). Zero third-party dependencies.

Build and run:

```sh
zig build bench -- --proxy 127.0.0.1:11080 -n 200 -c 16
```

Or run the installed binary directly:

```sh
zig-out/bin/zsocks-bench --proxy 127.0.0.1:11080 -n 200 -c 16 --list bench/sites.txt
```

Options:

```
--proxy <ip:port>   SOCKS5 proxy (IP literal, default 127.0.0.1:1080)
--user / --pass     SOCKS5 credentials
--list <file>       URL pool (default: built-in 21-site pool)
-n, --requests <N>  total requests (default 100)
-c, --concurrency   worker threads (default 10)
--seed <n>          PRNG seed for reproducible site selection
--insecure          skip TLS certificate/host verification
```

Reports req/s, total MB, Mbps, ttfb/total latency percentiles (p50/p95/p99/max),
per-site ok counts, and an error breakdown (connect / auth / tls / http / io).

> The proxy must be reachable by IP literal; targets are passed as domain ATYP so
> DNS happens on the proxy side, exercising zsocks' resolver path.

---

## 3. `lpbench.sh` — real browser via Lightpanda

Drives the [Lightpanda](https://github.com/lightpanda-io/browser) headless
browser through the proxy, so each request is an actual page load — full TLS,
JavaScript execution, and sub-resource fetches. This is the closest thing to
real user traffic. Lightpanda routes HTTP through libcurl, which speaks
`socks5h://` (remote DNS, matching zsocks' domain-ATYP behaviour).

```sh
# auto-download the nightly into bench/ on first run, then drive 20 page loads
bench/lpbench.sh --install --proxy 127.0.0.1:11080 -n 20
```

Subsequent runs (binary already present):

```sh
bench/lpbench.sh --proxy 127.0.0.1:11080 -n 50
bench/lpbench.sh --proxy 127.0.0.1:11081 --user zu --pass zp -n 20   # with auth
```

Options:

```
--proxy <host:port>    SOCKS5 proxy (default 127.0.0.1:1080)
--user / --pass        SOCKS5 credentials
--list <file>          URL pool (default bench/sites.txt)
-n, --requests <N>     page loads to perform (default 20)
--dump <html|markdown> Lightpanda output mode (default html)
--insecure             disable TLS host verification in the browser
--install              download the Lightpanda nightly for this platform
--lightpanda <path>    explicit path to the lightpanda binary
```

The binary is located via `--lightpanda`, `$LIGHTPANDA`, `./bench/lightpanda`,
`./lightpanda`, or `lightpanda` on `PATH`. The downloaded binary
(`bench/lightpanda`) is git-ignored. Reports per-load latency, captured content
size, success rate, and latency percentiles.

---

## Watching the bounded-memory guarantee

While any tool runs, sample the server RSS — it stays flat regardless of bytes
transferred:

```sh
ps -o rss= -p <zsocks-pid>
```
