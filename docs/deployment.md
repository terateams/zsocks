# Deploying zsocks

A practical, end-to-end guide to running `zsocks` in production — as a bare
binary, under systemd, in Docker, on a RouterOS container, and over IPv6.

`zsocks` is a single static binary with **no config file**: every setting is a
CLI flag, so deployment is just "get the binary (or image) and pass the right
arguments". Concurrency and buffers are capped up front, so memory is bounded
and predictable — safe to co-locate on a constrained router.

> TL;DR for the common case: run the GHCR image with host networking and let it
> listen dual-stack:
> ```sh
> docker run -d --restart unless-stopped --network host \
>   ghcr.io/terateams/zsocks:latest --listen :: -p 1080 -u alice -P secret --no-udp
> ```

---

## 1. Getting zsocks

You have three options. Pick one.

### a) Pre-built static binary (GitHub Releases)

Each tagged release attaches static, stripped musl binaries plus a checksum file:

- `zsocks-<version>-linux-amd64.tar.gz`
- `zsocks-<version>-linux-arm64.tar.gz`
- `zsocks-<version>-linux-armv7.tar.gz`
- `SHA256SUMS.txt`

```sh
ver=v0.1.0          # pick a released tag
arch=arm64          # amd64 | arm64 | armv7
base="https://github.com/terateams/zsocks/releases/download/${ver}"

curl -fsSLO "${base}/zsocks-${ver}-linux-${arch}.tar.gz"
curl -fsSLO "${base}/SHA256SUMS.txt"
sha256sum -c SHA256SUMS.txt --ignore-missing
tar -xzf "zsocks-${ver}-linux-${arch}.tar.gz"
sudo install -m 0755 "zsocks-${ver}-linux-${arch}/zsocks" /usr/local/bin/zsocks
zsocks --version
```

The binaries are fully static (no shared-library dependencies), so they run on
any Linux of the matching architecture, including minimal/musl systems.

### b) Container image (GHCR)

Multi-arch (amd64 / arm64 / arm-v7) on a ~3 MB `busybox:musl` base:

```sh
docker pull ghcr.io/terateams/zsocks:latest      # or :v0.1.0
```

### c) Build from source

Requires **Zig 0.16.0**.

```sh
git clone https://github.com/terateams/zsocks && cd zsocks
zig build -Doptimize=ReleaseSafe          # -> zig-out/bin/zsocks

# Cross-compile a static musl binary for another target:
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSmall
```

---

## 2. Command-line reference

```
zsocks [OPTIONS]

  -l, --listen <host>     Bind address (default 0.0.0.0)
  -p, --port <port>       Listen port (default 1080)
  -u, --user <name>       Username; enables RFC 1929 auth
  -P, --pass <pass>       Password (required with --user)
      --max-conns <n>     Max concurrent connections (default 256)
      --buf-size <bytes>  Relay buffer per direction (default 16384)
      --timeout <sec>     Socket idle timeout, 0=off (default 60)
      --no-udp            Disable UDP ASSOCIATE (TCP only)
      --udp-advertise <h> Address sent to clients for UDP relay
                          (use when behind NAT; default = listen host)
  -h, --help              Show help
  -v, --version           Show version
```

Notes:

- `--user` and `--pass` must be supplied **together**. Without them the proxy
  offers the *no-authentication* method.
- The proxy binds **one** socket. To serve both IPv4 and IPv6 clients, listen on
  `::` (dual-stack) rather than trying to bind `0.0.0.0` and `::` at once — see
  [§6 IPv6](#6-ipv6-deployment).

---

## 3. Running the binary directly

### Foreground (quick test)

```sh
# Open proxy on :1080
zsocks -p 1080

# With authentication and a smaller pool
zsocks -p 1080 -u alice -P secret --max-conns 128
```

### As a systemd service (recommended for a host)

Create a dedicated unit. The binary is static and does not need root; port 1080
is >1024 so no capabilities are required (if you bind a privileged port <1024,
add `AmbientCapabilities=CAP_NET_BIND_SERVICE`).

`/etc/systemd/system/zsocks.service`:

```ini
[Unit]
Description=zsocks SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/zsocks --listen :: -p 1080 -u alice -P secret --no-udp
Restart=on-failure
RestartSec=2

# Hardening (the proxy only needs to open sockets)
DynamicUser=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_INET AF_INET6
CapabilityBoundingSet=
AmbientCapabilities=
MemoryMax=64M

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now zsocks
systemctl status zsocks
journalctl -u zsocks -f          # startup banner + any errors go to stderr
```

> Put credentials in an `EnvironmentFile` if you don't want them in the unit /
> process list. zsocks itself takes only flags, so wrap with a small `ExecStart`
> that expands env vars, e.g. `ExecStart=/usr/local/bin/zsocks -u ${ZS_USER} -P ${ZS_PASS} ...`.

---

## 4. Docker

### Quick run

```sh
docker run -d --name zsocks --restart unless-stopped \
  -p 1080:1080 \
  ghcr.io/terateams/zsocks:latest -p 1080 -u alice -P secret
```

Everything after the image name is passed straight to `zsocks` as flags.

### docker compose

`compose.yaml`:

```yaml
services:
  zsocks:
    image: ghcr.io/terateams/zsocks:latest
    restart: unless-stopped
    # For IPv6 / dual-stack and reaching IPv6 targets, host networking is simplest:
    network_mode: host
    command: ["--listen", "::", "-p", "1080", "-u", "alice", "-P", "secret", "--no-udp"]
    # If you use a published port instead of host networking, drop network_mode
    # above and uncomment:
    # ports:
    #   - "1080:1080"
```

```sh
docker compose up -d
docker compose logs -f
```

### Networking: host vs. bridge

| Mode | Inbound | Outbound | Notes |
|------|---------|----------|-------|
| `--network host` | Uses the host's v4 **and** v6 stack | Reaches whatever the host can | **Simplest**, especially for IPv6 and for routers. Recommended. |
| Default bridge + `-p` | Only the published port | IPv4 to the internet via NAT | IPv4 works out of the box; **IPv6 needs extra Docker config** (see §6). |

### Healthcheck

The image ships a `HEALTHCHECK` that probes the SOCKS port with `nc -z`:

```dockerfile
ENV ZSOCKS_HEALTH_PORT=1080
HEALTHCHECK CMD nc -z 127.0.0.1 "$ZSOCKS_HEALTH_PORT" || exit 1
```

- If you change `-p`, also set `-e ZSOCKS_HEALTH_PORT=<port>`.
- The probe uses `127.0.0.1` (IPv4). With dual-stack (`--listen ::` on a normal
  Linux host) that's fine. On an **IPv6-only** host it would report unhealthy —
  override or disable the healthcheck there (see §6).

```sh
docker inspect --format '{{.State.Health.Status}}' zsocks
```

---

## 5. RouterOS container

RouterOS containers support exactly the arch set this image publishes
(amd64 / arm64 / arm-v7). You can pull from GHCR directly, or ship an **offline
tarball** (each release attaches `zsocks-image-<ver>-<arch>.tar.gz`).

### Option A — pull from GHCR

```rsc
/container/config/set registry-url=https://ghcr.io tmpdir=disk1/tmp
/container/add remote-image=ghcr.io/terateams/zsocks:latest \
    interface=veth1 \
    cmd="-p 1080 -u alice -P secret" \
    root-dir=disk1/zsocks logging=yes
/container/start 0
```

### Option B — offline tarball

```sh
# On a workstation: grab the release tarball (or `docker save` your own)
gunzip zsocks-image-0.1.0-arm64.tar.gz          # -> zsocks-image-0.1.0-arm64.tar
# upload zsocks-image-0.1.0-arm64.tar to the router (disk1)
```

```rsc
/container/add file=disk1/zsocks-image-0.1.0-arm64.tar \
    interface=veth1 \
    cmd="-p 1080 -u alice -P secret" \
    root-dir=disk1/zsocks logging=yes
/container/start 0
```

Tips:

- Make sure `veth1` is wired into a bridge with an address and the container has
  a default route (and DNS) so it can reach upstream targets. `logging=yes`
  surfaces the startup banner under `/log`.
- Because `--max-conns` and `--buf-size` cap memory up front, the proxy will not
  exhaust the router's RAM the way an unbounded proxy could. Size it for the
  device — see §7.

---

## 6. IPv6 deployment

What works out of the box vs. what you must configure:

| Capability | Status |
|------------|--------|
| **CONNECT to IPv6 targets** (`ATYP 0x04`, or a domain that resolves to AAAA) | ✅ Works with no special flags — even from an IPv4 client. |
| **Accepting IPv6 clients** (proxy reachable over IPv6) | ⚙️ Set `--listen ::`. |
| **UDP ASSOCIATE for IPv6 clients** | ❌ Not supported — the client-facing relay socket is IPv4-only. Use `--no-udp`, or keep UDP clients on IPv4. |

### Listen on IPv6 / dual-stack

```sh
zsocks --listen :: -p 1080 -u alice -P secret --no-udp
```

`--listen ::` binds an IPv6 socket. On a normal Linux host
(`net.ipv6.bindv6only = 0`, the default) this is **dual-stack**: it accepts both
IPv6 **and** IPv4 clients on the same port, and can CONNECT to both v4 and v6
targets. zsocks binds a single socket, so `::` is how you serve both families at
once (you cannot bind `0.0.0.0` and `::` in the same process).

Verify the default:

```sh
sysctl net.ipv6.bindv6only        # expect 0 (dual-stack). If 1, see caveats.
```

### The UDP caveat (important)

The UDP relay socket is **IPv4-only**. When `--listen` is an IPv6 address, the
address advertised to clients in the UDP ASSOCIATE reply resolves to IPv6 and
won't match the IPv4 relay socket, so UDP relaying breaks. Therefore:

- Serving IPv6 / dual-stack clients → add **`--no-udp`** (TCP CONNECT covers the
  vast majority of proxy use).
- If you need UDP ASSOCIATE, keep those clients on IPv4: `--listen 0.0.0.0`, or
  `--listen ::` **plus** `--udp-advertise <proxy-IPv4>`. UDP from IPv6 clients is
  not currently supported.

### Other IPv6 caveats

- **`bindv6only = 1` hosts**: `::` becomes IPv6-only, so IPv4 clients can't
  connect. Either set the sysctl back to `0`, or use `--listen 0.0.0.0` for an
  IPv4-only deployment.
- **Outbound IPv6 routing**: to *reach* IPv6 targets the host/container needs an
  IPv6 default route. `--network host` is the easiest way to inherit it.
- **Docker bridge + IPv6**: the default bridge is IPv4-only. Enable IPv6 in
  `/etc/docker/daemon.json`, e.g. `{"ipv6": true, "fixed-cidr-v6": "fd00::/64"}`,
  create an IPv6-enabled network, publish `-p '[::]:1080:1080'`, and arrange
  NAT66/routing for egress — or just use `--network host`.
- **Healthcheck on IPv6-only**: the image probes `nc -z 127.0.0.1`; on a pure
  IPv6 host override it, e.g. `--health-cmd 'nc -z ::1 1080 || exit 1'` (or
  `--no-healthcheck`).

---

## 7. Resource sizing & memory model

Memory is bounded by two flags. Peak usage is fixed at startup:

```
TCP peak  ≈ max-conns × (2 × buf-size)
UDP peak  ≈ (active UDP associations) × ~131 KB     (≤ max-conns)
```

The accept loop **rejects** new connections once `--max-conns` is reached, so
the proxy never grows unboundedly.

| Profile | Flags | TCP relay pool |
|---------|-------|----------------|
| Default | `--max-conns 256 --buf-size 16384` | ~8 MiB |
| Constrained router | `--max-conns 64 --buf-size 8192` | ~1 MiB |
| Tiny | `--max-conns 32 --buf-size 4096` | ~256 KiB |
| High throughput | `--max-conns 512 --buf-size 65536` | ~64 MiB |

Observed resident memory (RSS) is typically ~10 MB for the default profile.
zsocks uses a thread-per-connection model; thread stacks are mostly virtual
(lazily paged), so they add little to RSS, but factor in your kernel's
per-thread limits if you push `--max-conns` very high.

Set a hard ceiling at the platform level too: systemd `MemoryMax=`, Docker
`--memory`, or RouterOS container RAM limits.

---

## 8. Authentication

```sh
zsocks -p 1080 -u alice -P secret
```

- Enables RFC 1929 username/password (method `0x02`). Without `-u/-P` the proxy
  offers *no authentication* (`0x00`) — only do that on a trusted network or
  behind a firewall.
- Username and password are each limited to 255 bytes.
- There is a single credential pair. For multiple users or rotation, run
  multiple instances on different ports or front it with your own access layer.

Because there is no TLS on the SOCKS control channel, treat credentials as
network-visible on untrusted links. Restrict exposure with a firewall (only
allow your client networks to reach the port) and/or tunnel over WireGuard/SSH.

---

## 9. Timeouts & reliability

- `--timeout <sec>` (default 60) is an **idle** socket timeout applied to the
  relay; `0` disables it. Lower it on busy or hostile networks to reclaim
  connection-pool slots faster.
- Always run under a supervisor that restarts on exit: systemd
  `Restart=on-failure`, Docker `--restart unless-stopped`, or RouterOS
  `start-on-boot`.

---

## 10. Verifying a deployment

Replace host/port/credentials as needed.

```sh
# TCP CONNECT (IPv4 target) through the proxy
curl --socks5-hostname alice:secret@127.0.0.1:1080 https://example.com/ -I

# CONNECT to an IPv6 target (literal address, ATYP 0x04)
curl --socks5-hostname alice:secret@127.0.0.1:1080 'http://[2606:4700:4700::1111]/' -I

# Reach the proxy over IPv6 (proxy started with --listen ::)
curl --socks5-hostname 'alice:secret@[::1]:1080' https://example.com/ -I
```

A `200`/`3xx`/headers response means the full negotiation + relay path works.

For UDP ASSOCIATE (IPv4 clients only) the simplest check is a DNS-over-UDP
client configured to use the SOCKS5 proxy, or the project's hermetic
`test/e2e.sh`, which exercises TCP CONNECT, auth accept/reject, and a UDP echo
round-trip locally.

---

## 11. Upgrading

- **Binary**: download the new release tarball, verify the checksum, replace
  `/usr/local/bin/zsocks`, then `systemctl restart zsocks`.
- **Docker / compose**: `docker pull ghcr.io/terateams/zsocks:<new-tag>` then
  recreate the container (`docker compose up -d`).
- **RouterOS**: stop and remove the container, `add` the new image/tarball,
  start again. Keep the same `root-dir`/`cmd`.

`zsocks --version` reports the running build (the version is single-sourced from
`build.zig.zon`).

---

## 12. Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `cannot resolve listen address '<x>'` at startup | Bad `--listen` value, or no matching address family on the host. Use `0.0.0.0`, `::`, or a literal local address. |
| `--user requires --pass` (or vice-versa) | Supply both `-u` and `-P`, or neither. |
| IPv4 clients can't connect to a `--listen ::` proxy | Host has `net.ipv6.bindv6only=1` → `::` is IPv6-only. Set it to `0`, or use `--listen 0.0.0.0`. |
| New connections refused/hang under load | `--max-conns` reached (by design). Raise it (mind memory) or lower `--timeout` to recycle idle slots faster. |
| UDP ASSOCIATE fails | Disabled (`--no-udp`), client is IPv6 (unsupported), or you're behind NAT — set `--udp-advertise <reachable-host>`. |
| Container marked `unhealthy` | Healthcheck probes `127.0.0.1:$ZSOCKS_HEALTH_PORT`. Align `ZSOCKS_HEALTH_PORT` with `-p`; on IPv6-only hosts override the healthcheck (§6). |
| Can't reach IPv6 sites from the proxy | Host/container lacks an IPv6 default route. Use `--network host` or configure Docker IPv6 egress. |
| No logs after the startup banner | By design the proxy is quiet. Run the container with `logging=yes` (RouterOS) or check `journalctl`/`docker logs` for the banner and any errors. |

---

See the top-level [README](../README.md) for protocol support and limitations,
and [AGENT.md](../AGENT.md) for build/test details.
