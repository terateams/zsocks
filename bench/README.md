# Benchmarks

Two complementary tools that drive **real traffic through the proxy**:

| Tool | Driver | Target | Measures |
|------|--------|--------|----------|
| `bench.zig` | Zig (`zig build bench`) | pool of **real public HTTPS sites** | end-to-end proxy throughput + latency over real TLS |
| `lpbench.sh` | [Lightpanda](https://github.com/lightpanda-io/browser) headless browser | pool of real sites | real page loads (full TLS + JS) through the proxy |

Both pick targets **randomly per request** from a shared pool so no single
origin rate-limits a run. Five pools are provided:

- [`sites.txt`](./sites.txt) — combined global + China pool (default).
- [`sites-global.txt`](./sites-global.txt) — overseas origins only.
- [`sites-cn.txt`](./sites-cn.txt) — China-mainland origins only.
- [`sites-cn-bw.txt`](./sites-cn-bw.txt) — China-mainland **large files** (24–70 MB
  across 7 mirror hosts) for measuring peak download throughput without a single
  mirror throttling the run. Use with `bench.zig` and a modest count, e.g.
  `--list bench/sites-cn-bw.txt -n 40 -c 16`. Not for `lpbench.sh` (the browser
  won't render tarballs).
- [`sites-global-bw.txt`](./sites-global-bw.txt) — overseas **large files**
  (12–87 MB across 8 distinct CDN hosts: Google, Cloudflare, Mozilla, Fastly,
  OpenJS, OVH, Tele2) — the international counterpart of `sites-cn-bw.txt` for
  measuring peak download throughput on cross-border routes. Use with
  `bench.zig`, e.g. `--list bench/sites-global-bw.txt -n 40 -c 16`.

Testing the two regional lists separately makes it easy to tell a cross-border
line problem apart from a proxy problem.

Start a proxy first (ReleaseFast recommended for realistic numbers):

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/zsocks -l 127.0.0.1 -p 11080 --max-conns 512
```

---

## 1. `bench.zig` — real-internet load generator (zero deps)

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

## 2. `lpbench.sh` — real browser via Lightpanda

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
