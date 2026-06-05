# zsocks runtime / deployment image.
#
# The product contract is a single static musl binary with zero third-party
# dependencies. The final stage layers that one binary onto $RUNTIME_BASE
# (default `busybox:musl`), which adds a tiny shell + core utilities (incl. `nc`)
# for in-container debugging and the healthcheck. The daemon itself needs nothing
# from the base — it is fully static.
#
# Multi-arch is produced WITHOUT qemu: the build stage is pinned to the native
# BUILDPLATFORM and Zig cross-compiles to the requested TARGETARCH. The final
# stage only copies the binary onto the matching-arch base layer, so it needs no
# emulation either. busybox:musl publishes amd64, arm64 and arm/v7 — exactly the
# architectures RouterOS's container feature supports.
#
#   docker build -t zsocks .
#   docker run --rm -p 1080:1080 zsocks -p 1080
#   docker run --rm -p 1080:1080 zsocks -p 1080 -u alice -P secret

# Runtime base for the final stage. Overridable (e.g. RUNTIME_BASE=scratch) for a
# shell-less, musl-pure image on architectures busybox:musl does not publish.
ARG RUNTIME_BASE=busybox:1.37.0-musl

# --- build stage: cross-compile the static binary with Zig -------------------
FROM --platform=$BUILDPLATFORM debian:stable-slim AS build

ARG ZIG_VERSION=0.16.0
# Pinned upstream SHA256 sums (from https://ziglang.org/download/index.json).
ARG ZIG_SHA256_X86_64=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
ARG ZIG_SHA256_AARCH64=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
# Provided automatically by BuildKit.
ARG BUILDARCH
ARG TARGETARCH
ARG TARGETVARIANT

RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils; \
    rm -rf /var/lib/apt/lists/*

# Install the Zig toolchain for the BUILD host arch (no emulation).
RUN set -eux; \
    case "${BUILDARCH}" in \
        amd64) ZIG_ARCH=x86_64;  ZIG_SHA="${ZIG_SHA256_X86_64}" ;; \
        arm64) ZIG_ARCH=aarch64; ZIG_SHA="${ZIG_SHA256_AARCH64}" ;; \
        *) echo "unsupported BUILDARCH=${BUILDARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz"; \
    curl -fsSL "$url" -o /tmp/zig.tar.xz; \
    echo "${ZIG_SHA}  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src

# Map the Docker TARGETARCH/TARGETVARIANT to a Zig musl triple + CPU model and
# cross-compile ReleaseSmall. Targeting *-linux-musl with libc statically links
# by default, so the artifact is a single self-contained binary.
#   linux/amd64   -> x86_64-linux-musl
#   linux/arm64   -> aarch64-linux-musl
#   linux/arm/v7  -> arm-linux-musleabihf  -Dcpu=generic+v7a (hard float)
RUN set -eux; \
    case "${TARGETARCH}/${TARGETVARIANT}" in \
        amd64/*)   ZIG_TARGET=x86_64-linux-musl;    ZIG_CPU= ;; \
        arm64/*)   ZIG_TARGET=aarch64-linux-musl;   ZIG_CPU= ;; \
        arm/v7)    ZIG_TARGET=arm-linux-musleabihf; ZIG_CPU="-Dcpu=generic+v7a" ;; \
        arm/*)     ZIG_TARGET=arm-linux-musleabihf; ZIG_CPU="-Dcpu=generic+v7a" ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH} TARGETVARIANT=${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    zig build -Dtarget="${ZIG_TARGET}" ${ZIG_CPU} -Doptimize=ReleaseSmall; \
    test -x zig-out/bin/zsocks

# --- final stage: busybox/musl runtime base + the static binary --------------
FROM ${RUNTIME_BASE}

COPY --from=build /src/zig-out/bin/zsocks /usr/local/bin/zsocks

# Liveness for orchestrators (docker/compose/k8s): probe that the SOCKS port is
# accepting connections. ZSOCKS_HEALTH_PORT defaults to the image's default
# listen port (1080); override it if you run with a different -p. Uses busybox
# `nc -z` (zero-I/O TCP scan).
ENV ZSOCKS_HEALTH_PORT=1080
HEALTHCHECK --interval=30s --timeout=3s --start-period=3s --retries=3 \
    CMD nc -z 127.0.0.1 "$ZSOCKS_HEALTH_PORT" || exit 1

EXPOSE 1080
ENTRYPOINT ["/usr/local/bin/zsocks"]
CMD ["-l", "0.0.0.0", "-p", "1080"]
