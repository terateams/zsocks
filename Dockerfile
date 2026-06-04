# Multi-stage build: compile a fully static musl binary with the Zig toolchain,
# then ship it in an empty `scratch` image. The result is a single static
# executable with no runtime dependencies — ideal for a RouterOS container.
#
#   docker build -t zsocks .
#   docker run --rm -p 1080:1080 zsocks -p 1080
#
# Build for a specific RouterOS architecture (arm64 / arm / amd64):
#   docker build --build-arg TARGET=aarch64-linux-musl     -t zsocks:arm64 .
#   docker build --build-arg TARGET=arm-linux-musleabihf   -t zsocks:arm   .
#   docker build --build-arg TARGET=x86_64-linux-musl      -t zsocks:amd64 .

ARG ZIG_VERSION=0.16.0
ARG TARGET=x86_64-linux-musl

FROM alpine:3.20 AS build
ARG ZIG_VERSION
ARG TARGET
RUN apk add --no-cache curl xz
WORKDIR /src
# Fetch the Zig toolchain matching the build host architecture.
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  ZARCH=x86_64 ;; \
      aarch64) ZARCH=aarch64 ;; \
      *) echo "unsupported build host arch: $(uname -m)"; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZARCH}-${ZIG_VERSION}.tar.xz" \
      | tar -xJ; \
    mv "zig-linux-${ZARCH}-${ZIG_VERSION}" /opt/zig
ENV PATH="/opt/zig:${PATH}"
COPY build.zig build.zig.zon ./
COPY src ./src
# Cross-compile a stripped, fully static musl binary for the requested target.
RUN zig build -Dtarget="${TARGET}" -Doptimize=ReleaseSafe --prefix /out

FROM scratch
COPY --from=build /out/bin/zsocks /zsocks
EXPOSE 1080
ENTRYPOINT ["/zsocks"]
CMD ["-l", "0.0.0.0", "-p", "1080"]
