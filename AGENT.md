# AGENT.md

Guidance for AI coding agents working in this repository.

## What this is

`zsocks` is a tiny, **zero-dependency** SOCKS5 proxy written in Zig. It targets
container deployment on RouterOS (and anywhere) without preempting host
resources. Design constraints that drive every decision:

- **Zero third-party dependencies** — only the Zig std library + libc. Do not
  add packages to `build.zig.zon` or pull in external crates/libs.
- **Bounded, configurable memory** — concurrency is capped (`--max-conns`) and
  relay buffers are pre-allocated up front, so peak memory is fixed and
  predictable. Never introduce per-connection unbounded allocation.
- **No config file** — every setting is a CLI flag so it drops into a container
  `CMD` line cleanly. Do not add config-file parsing.
- **Single static musl binary** — release artifacts must stay self-contained and
  small (CI enforces a ≤512 KB size budget on ReleaseSmall builds).

## Toolchain

- **Zig 0.16.0** (pinned; see `build.zig.zon` `minimum_zig_version`). The 0.16
  std library is significantly different from earlier versions — `std.net` and
  most `std.posix` socket helpers were removed, so socket I/O goes through
  `std.c` directly (see `src/net.zig`). The new `std.Io` interface is used in
  `bench/bench.zig`. Don't assume pre-0.16 APIs exist.

## Layout

```
src/
  main.zig      Entry point (pub fn main(init: std.process.Init)); arg vector → Config → Server
  Config.zig    CLI flags + parsing. version comes from build_options (single source of truth)
  server.zig    Accept loop + fixed-size connection/buffer pool (the memory bound lives here)
  net.zig       Zero-alloc libc socket wrappers via std.c (TCP + UDP, exact byte layouts)
  socks5.zig    RFC 1928 negotiation/CONNECT/UDP ASSOCIATE + RFC 1929 auth + relay loops
  tests.zig     Unit test aggregator (imports module tests)
test/e2e.sh     Hermetic end-to-end test (curl TCP+auth, python3 UDP echo, RSS check)
bench/          Benchmark tools (see bench/README.md) — NOT part of the proxy binary
Dockerfile      Static-binary container (busybox/scratch style)
.github/workflows/  ci.yml (test + cross-build + e2e + docker), release.yml
```

## Build / test / run

```sh
zig build                       # debug build → zig-out/bin/zsocks
zig build -Doptimize=ReleaseSafe   # what e2e uses
zig build -Doptimize=ReleaseSmall  # what release/CI size budget uses
zig build test                  # unit tests
bash test/e2e.sh                # hermetic functional test (needs curl + python3)
zig build release               # cross-compile static musl binaries for all triples
zig-out/bin/zsocks -p 1080      # run an open proxy
```

Release targets (static, ReleaseSmall): `x86_64-linux-musl`,
`aarch64-linux-musl`, `arm-linux-musleabihf`.

### Always verify before committing

Run all three and confirm green:

```sh
zig build && zig build test && bash test/e2e.sh
```

Note: `zig build test` prints `zsocks: --user requires --pass` to stderr from a
negative-path test — that is expected; the run still exits 0.

## Conventions

- **Version is single-sourced** from `build.zig.zon` `.version`, injected via
  `build_options` and re-exported as `Config.version`. Never hardcode a version
  string in source.
- Match the existing terse, purposeful comment style: file-level `//!` doc
  comments explaining *why* a module exists; comment only non-obvious logic.
- Keep allocations out of the hot path. New per-connection state must come from
  the pre-sized pool in `server.zig`, not fresh allocations.
- Socket syscalls go through `src/net.zig` wrappers, not ad-hoc `std.c` calls
  scattered across modules.

## Benchmarks (not shipped in the binary)

`bench/` contains two real-traffic load tools — `bench.zig`
(`zig build bench -- ...`, a zero-dependency Zig SOCKS5 load generator) and
`lpbench.sh` (drives the Lightpanda headless browser through the proxy). They
share `bench/sites.txt` and pick targets randomly to avoid single-origin rate
limiting. See `bench/README.md`. The downloaded `bench/lightpanda` binary is
git-ignored. Benchmarks are standalone and must not be linked into or depended
on by the proxy.

## Don'ts

- Don't add third-party dependencies.
- Don't add a config-file mechanism.
- Don't introduce unbounded or per-request heap growth.
- Don't break the static-binary / size-budget guarantees.
- Don't assume pre-0.16 Zig std APIs.
