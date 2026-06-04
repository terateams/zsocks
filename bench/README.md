# Benchmarks

`bench.py` is a zero-dependency (stdlib-only) load generator for measuring
zsocks performance on loopback. It spins up an in-process backend TCP data
server and drives load both **directly** (baseline) and **through the proxy**,
so the numbers isolate the proxy's relay overhead.

## Usage

Start the proxy (ReleaseFast recommended for realistic numbers):

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/zsocks -l 127.0.0.1 -p 11080 --max-conns 512
```

Run the benchmark:

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

## What it measures

- **throughput** — N parallel connections each downloading `--payload-mb`,
  reported as MB/s and Mbps (proxy vs. direct baseline).
- **conn-rate** — `--rate-total` short connections at `--rate-conc`
  concurrency, reported as conn/s with p50/p99 setup latency.

To watch the bounded-memory guarantee, sample the server RSS while it runs:

```sh
ps -o rss= -p <pid>   # stays flat regardless of bytes transferred
```

> Loopback numbers are dominated by memory-copy bandwidth and the Python
> client, so absolute figures are far higher than any real NIC. They are useful
> as a *relative* measure of proxy overhead and for confirming memory stays
> bounded.
