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

A multi-stage `Dockerfile` produces a `scratch`-based image containing only the
static binary:

```sh
# Build for the target architecture (RouterOS supports arm64 / arm / amd64)
docker build --build-arg TARGET=aarch64-linux-musl -t zsocks:arm64 .

# Export a rootfs tarball for RouterOS's container package
docker save zsocks:arm64 -o zsocks-arm64.tar
```

Deploy on RouterOS (container package must be installed):

```
/container/config/set registry-url=... tmpdir=...
/container/add file=zsocks-arm64.tar interface=veth1 \
    cmd="-p 1080 -u alice -P secret" root-dir=disk1/zsocks
/container/start 0
```

Because concurrency and buffers are capped, the proxy will not exhaust the
router's RAM the way an unbounded proxy could.

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
