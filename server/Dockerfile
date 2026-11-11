FROM ubuntu:22.04 AS build
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    build-essential cmake ninja-build pkg-config libssl-dev libclang-dev \
    libsqlite3-dev libcurl4-openssl-dev nlohmann-json3-dev ffmpeg python3
ARG USERVER_VERSION=3.2
RUN curl -fsSL "https://github.com/userver-framework/userver/releases/download/v${USERVER_VERSION}/ubuntu22.04-libuserver-all-dev_${USERVER_VERSION}_amd64.deb" -o /tmp/userver.deb \
    && echo 'e3b0a7e2c0d44193f6ca7fc87fc9ebbaea364a84ab0fbc8daf6f4c1533d16475  /tmp/userver.deb' | sha256sum -c - \
    && apt-get install -y /tmp/userver.deb && rm /tmp/userver.deb
WORKDIR /src
COPY rust_backend/rust-toolchain.toml rust_backend/rust-toolchain.toml
RUN curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --profile minimal --default-toolchain none
ENV PATH="/root/.cargo/bin:${PATH}"
COPY rust_backend rust_backend
RUN cd rust_backend && cargo build --locked --release -p mornye-extensions --bin music-extension-worker
COPY server server
RUN cmake -S server -B /build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    && cmake --build /build -j2 && ctest --test-dir /build --output-on-failure
RUN mkdir -p /runtime/usr/local/bin \
    && cp /build/music-server /build/music-admin rust_backend/target/release/music-extension-worker /runtime/usr/local/bin/ \
    && python3 server/scripts/copy_runtime_libraries.py /runtime

FROM ubuntu:22.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates ffmpeg util-linux \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home music \
    && mkdir /data && chown music:music /data
COPY --from=build /runtime/ /
COPY LICENSE COPYING NOTICE /usr/share/doc/libremusic/
COPY server/config/static.yaml /etc/music/static.yaml
ENV MUSIC_CONFIG=/etc/music/private/service.json
USER music
EXPOSE 8080
ENTRYPOINT ["music-server", "--config", "/etc/music/static.yaml"]
