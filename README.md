# zsocks

A tiny, **zero-dependency** SOCKS5 proxy written in [Zig](https://ziglang.org).
Built to run as a lightweight container on **RouterOS** (or anywhere) without
preempting host resources.

## Features

- **Zero third-party dependencies** — only the Zig std library + libc.
- **Bounded, configurable memory** — concurrency is capped and buffers are
  pre-sized, so peak memory is predictable.
- **SOCKS5 TCP `CONNECT`** and **UDP `ASSOCIATE`** (RFC 1928).
- **Username/password authentication** (RFC 1929), optional.
- **No config file** — everything is set through CLI flags.
- Ships as a single **static musl binary** (arm64 / arm / x86_64).

## Quick start

```sh
# Build (requires Zig 0.16.0)
zig build

# Run an open proxy on :1080
zig-out/bin/zsocks -p 1080

# With authentication
zig-out/bin/zsocks -p 1080 -u alice -P secret

# Test it
curl --socks5-hostname alice:secret@127.0.0.1:1080 https://example.com/
```

## Usage

```
zsocks [OPTIONS]

OPTIONS:
  -l, --listen <host>     Bind address (default 0.0.0.0)
  -p, --port <port>       Listen port (default 1080)
  -u, --user <name>       Username; enables RFC1929 auth
  -P, --pass <pass>       Password (required with --user)
      --max-conns <n>     Max concurrent connections (default 256)
      --buf-size <bytes>  Relay buffer per direction (default 16384)
      --timeout <sec>     Socket idle timeout, 0=off (default 60)
      --no-udp            Disable UDP ASSOCIATE (TCP only)
      --udp-advertise <h> Address sent to clients for UDP relay
                          (use when behind NAT; default = listen host)
  -h, --help              Show this help
  -v, --version           Show version
```

When `--user`/`--pass` are omitted the proxy offers the *no-authentication*
method. Both flags must be supplied together.

## Memory model

Memory is intentionally bounded so the proxy is safe to co-locate with other
services on a constrained device:

- The accept loop rejects connections once `--max-conns` is reached; it never
  grows unboundedly.
- Each TCP connection uses two relay buffers of `--buf-size` bytes
  (one per direction), pre-allocated from a fixed pool.
- Each active UDP association adds ~131 KB of relay buffers (two 64 KiB
  datagram buffers).

```
TCP peak  ≈ max-conns × (2 × buf-size)
UDP peak  ≈ (active associations) × ~131 KB     (≤ max-conns)
```

With the defaults (`max-conns=256`, `buf-size=16384`) the TCP relay pool is
~8 MiB.

## Building static release binaries

```sh
zig build release
# -> zig-out/x86_64-linux-musl/zsocks
#    zig-out/aarch64-linux-musl/zsocks
#    zig-out/arm-linux-musleabihf/zsocks
```

Each is a fully static, stripped ELF with no shared-library dependencies.

You can also cross-compile any single target directly:

```sh
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe
```

## Docker / RouterOS container

The multi-stage `Dockerfile` cross-compiles the static binary with Zig (no qemu)
and ships it on a tiny **`busybox:musl`** base — a ~3 MB image that still
includes a shell, `nc`, and core utilities for in-container debugging while the
daemon itself stays fully static.

### Pull a pre-built image (GHCR)

Released tags publish a multi-arch manifest (amd64 / arm64 / arm/v7 — the set
RouterOS containers support):

```sh
docker run --rm -p 1080:1080 ghcr.io/jamiesun/zsocks:latest -p 1080 -u alice -P secret
```

### Build locally

```sh
# BuildKit injects TARGETARCH; build for the current host by default
docker build -t zsocks .

# Or pick an architecture explicitly
docker build --build-arg TARGETARCH=arm64 -t zsocks:arm64 .
```

The image has a `HEALTHCHECK` that probes the SOCKS port with `nc -z`
(`ZSOCKS_HEALTH_PORT`, default `1080`).

### Deploy on RouterOS

Pull from GHCR directly, or export an offline tarball (release runs attach these
as `zsocks-image-<ver>-<arch>.tar.gz` artifacts):

```sh
docker save ghcr.io/jamiesun/zsocks:latest -o zsocks.tar
```

```
/container/config/set registry-url=https://ghcr.io tmpdir=disk1/tmp
/container/add file=zsocks.tar interface=veth1 \
    cmd="-p 1080 -u alice -P secret" root-dir=disk1/zsocks
/container/start 0
```

Because concurrency and buffers are capped, the proxy will not exhaust the
router's RAM the way an unbounded proxy could.

## Continuous integration & releases

- **CI** (`.github/workflows/ci.yml`, on push/PR): unit tests, a cross-build
  matrix asserting each musl target is statically linked and within a 512 KB
  budget, a hermetic functional e2e (`test/e2e.sh`: TCP CONNECT, auth accept/
  reject, UDP ASSOCIATE echo), and a busybox image build+proxy smoke test.
- **Release** (`.github/workflows/release.yml`, on `v*` tags): a version guard
  (tag must equal `build.zig.zon` `.version`), the e2e gate, static binary
  tarballs + `SHA256SUMS.txt` attached to a GitHub Release, and a multi-arch
  busybox image (plus offline tarballs) pushed to GHCR.

Run the e2e suite locally with:

```sh
bash test/e2e.sh        # builds, then exercises TCP/auth/UDP through the proxy
```

### Versioning & cutting a release

The version lives in **exactly one place** — `build.zig.zon`'s `.version`.
`build.zig` imports it (`@import("build.zig.zon").version`) and injects it into
the binary through a `build_options` module, so `zsocks --version`, the startup
banner, and the release artifacts all derive from that single field — no source
constant to keep in sync.

To release `X.Y.Z`:

```sh
# 1. bump the single source of truth
sed -i 's/\.version = ".*"/.version = "X.Y.Z"/' build.zig.zon
git commit -am "Release vX.Y.Z"

# 2. tag and push — the release workflow's guard fails if the tag and
#    build.zig.zon .version disagree
git tag vX.Y.Z
git push origin main --tags
```

## Protocol support & limitations

- Methods: `0x00` (no-auth), `0x02` (username/password). `BIND` is **not**
  supported (returns *command not supported*).
- `CONNECT`: IPv4, IPv6 and domain-name targets (`ATYP` 0x01/0x03/0x04).
- `UDP ASSOCIATE`: relays datagrams to IPv4 and IPv6 targets. The relay socket
  the proxy binds for the client is **IPv4-only**, and the association is
  pinned to the first client endpoint (full address + port). Fragmented
  datagrams (`FRAG ≠ 0`) are dropped, per common practice.

## Notes on Zig 0.16

Zig 0.16 removed `std.net` and the `std.posix` socket wrappers. zsocks talks to
the kernel through libc (`std.c`) directly, which keeps the binary tiny and
fully static when linked against musl.

## License

MIT
