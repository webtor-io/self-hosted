ARG ALPINE_VER="3.22"
ARG S6_OVERLAY_VER="3.2.0.2"
ARG S6_VERBOSITY=1

# Component images are pinned by tag AND digest so Renovate can bump them
# one at a time and each component's provenance is fully reproducible.
# Nothing is compiled here any more. The Alpine base below and its apk
# packages are NOT pinned to a digest and will float to whatever `apk add`
# resolves at build time.
FROM ghcr.io/webtor-io/torrent-store:master@sha256:d0ef32515426b511b1326a03dc941ce16463e3d1713b607694f02e7ff7b9e67c AS torrent-store
FROM ghcr.io/webtor-io/magnet2torrent:master@sha256:cb5e582d9f1c82df367ac85b91972c4bf799dc9a41515e66993b3c9e139661f7 AS magnet2torrent
FROM ghcr.io/webtor-io/external-proxy:master@sha256:fb83696ca24053660a7b43cb1cbb830f2104d6fe31acc0eb2c5fdf283ae7abbf AS external-proxy
FROM ghcr.io/webtor-io/torrent-web-seeder:master@sha256:08c961f706e7a5725189d3bbf97a74100091fc691f0e5b5fd6c11734eed71866 AS torrent-web-seeder
FROM ghcr.io/webtor-io/torrent-web-seeder-cleaner:main@sha256:767e017b2adc53c07ebc65f4073cb6341fd460a1c688105edcc3a615e000a8c1 AS torrent-web-seeder-cleaner
FROM ghcr.io/webtor-io/content-transcoder:master@sha256:1a0b96c8f243bbf45c8b3d4b60af5f5b302689e9d4dc2c5c339d155fd99fc3bf AS content-transcoder
FROM ghcr.io/webtor-io/content-prober:master@sha256:3bd658a5dfb8ab64bb6ffa46346b043436eb73473a3bf024dccc0fe333a9e400 AS content-prober
FROM ghcr.io/webtor-io/torrent-archiver:master@sha256:f2a44e53c4e251c10e1f26dbcd75cceb5fd9bca0ade7aa39a279a547e2aca7df AS torrent-archiver
FROM ghcr.io/webtor-io/srt2vtt:master@sha256:084bc8b1810768242a6c986345f7b7e0e5b162921333b4114241605e3a6cfa86 AS srt2vtt
FROM ghcr.io/webtor-io/subtitle-translate:master@sha256:09c5590b171e81654ef640e2c0a2609b2578e5ed0a9f2849b8ffa9edf308fb98 AS subtitle-translate
FROM ghcr.io/webtor-io/video-info:master@sha256:66cef3cfe61a9ae2ebec2d6f8f54d5dc9d3bbb06251b4737fac17b39dc8435c7 AS video-info
FROM ghcr.io/webtor-io/torrent-http-proxy:master@sha256:df88e17e400af87d2471ed38ea12e4bcd656b44cdb05d79df1f894a6828407b4 AS torrent-http-proxy
FROM ghcr.io/webtor-io/rest-api:main@sha256:4e5f282de24789f49a17586ec23bc930bad79f36c3bed08528c2bb470c06b722 AS rest-api
FROM ghcr.io/webtor-io/web-ui:main@sha256:734ddc735f4f535e48b4633e7e00f682257a268726a7ab7730c653c1c3fed5e0 AS web-ui
FROM ghcr.io/webtor-io/nginx-vod:main@sha256:fd1f4fa696e945b73019981d7f077d429035a304bead2125adf1e689a097a2d6 AS nginx-vod
FROM ghcr.io/webtor-io/vault:main@sha256:9eeafa430d1df73ddd1f9460f3c34ed46d909df19c413a473a2dfefc0dfc88f1 AS vault

# Not a webtor component: the S3 gateway backing /storage. Apache 2.0, one
# static binary, and its posix backend keeps objects as ordinary files so a
# self-hoster can read their own data without this program. Pinned like every
# other stage; Renovate does not watch it (renovate.json matches
# ghcr.io/webtor-io/**), so bumps here are deliberate and manual.
FROM ghcr.io/versity/versitygw:latest@sha256:c4cbd9d9cb8dedbb055ac788dbd02635651b9b1cebac95b095b3217231aa87ad AS versitygw

# Not webtor components: the event bus and the CLI that provisions its stream.
# Both publish linux/amd64 and linux/arm64. Renovate does not watch either
# (renovate.json matches ghcr.io/webtor-io/**), so bumps here are manual.
FROM nats:alpine@sha256:d4ac35882ac65aff236cd65b9d3fa4d24332c681e1a85f94eedccd3cdd65b1da AS nats
FROM natsio/nats-box:latest@sha256:ffce8bd103383f179f8c7f11cf645726acf5d17280706c530c3b342dbe16334c AS natsbox

FROM alpine:${ALPINE_VER}

ARG S6_OVERLAY_VER
ARG S6_VERBOSITY
ARG TARGETARCH
ENV S6_VERBOSITY=$S6_VERBOSITY

LABEL org.opencontainers.image.source="https://github.com/webtor-io/self-hosted"

RUN apk --no-cache add redis ffmpeg ca-certificates openssl pcre zlib envsubst uuidgen \
    postgresql postgresql-client postgresql-contrib curl attr

ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VER}/s6-overlay-noarch.tar.xz /tmp/
RUN tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && rm /tmp/s6-overlay-noarch.tar.xz

# s6-overlay ships per-arch tarballs under names that do not match TARGETARCH.
RUN case "$TARGETARCH" in \
      amd64) s6arch=x86_64 ;; \
      arm64) s6arch=aarch64 ;; \
      *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/s6-overlay-arch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VER}/s6-overlay-${s6arch}.tar.xz" && \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz && \
    rm /tmp/s6-overlay-arch.tar.xz

WORKDIR /app

# Binary names must match what the s6 run scripts invoke (/app/<service>).
COPY --from=torrent-store /server ./torrent-store
COPY --from=magnet2torrent /server ./magnet2torrent
COPY --from=external-proxy /server ./external-proxy
COPY --from=torrent-web-seeder /server ./torrent-web-seeder
COPY --from=torrent-web-seeder-cleaner /server ./torrent-web-seeder-cleaner
COPY --from=torrent-archiver /server ./torrent-archiver
COPY --from=srt2vtt /server ./srt2vtt
COPY --from=subtitle-translate /server ./subtitle-translate
COPY --from=video-info /server ./video-info
COPY --from=torrent-http-proxy /server ./torrent-http-proxy
COPY --from=rest-api /server ./rest-api
COPY --from=versitygw /usr/local/bin/versitygw ./versitygw
COPY --from=nats /usr/local/bin/nats-server ./nats-server
COPY --from=natsbox /usr/local/bin/nats ./nats
COPY --from=content-transcoder /app/server ./content-transcoder
COPY --from=content-transcoder /app/player ./player
# Only the binary: it shells out to ffprobe, which this image already carries
# for content-transcoder.
COPY --from=content-prober /app/server ./content-prober
COPY --from=web-ui /app/server ./web-ui/web-ui
COPY --from=web-ui /app/templates ./web-ui/templates
COPY --from=web-ui /app/pub ./web-ui/pub
COPY --from=web-ui /app/migrations ./web-ui/migrations
COPY --from=web-ui /app/assets/dist ./web-ui/assets/dist
COPY --from=nginx-vod /usr/local/nginx /usr/local/nginx

# Vault gets its own working directory, not /app, because common-services
# discovers migrations at the CWD-relative path "migrations". Since web-ui
# moved into ./web-ui above, /app/migrations does not exist for anyone --
# started from /app, vault would silently discover zero migrations, create
# an empty gopg_migrations table, and never create its own schema.
COPY --from=vault /server ./vault/vault
COPY --from=vault /migrations ./vault/migrations

COPY etc/webtor /etc/webtor
COPY etc/nginx/conf /usr/local/nginx/conf
COPY s6-overlay /etc/s6-overlay
COPY cont-init.d /etc/cont-init.d

RUN find /etc/s6-overlay -type f \( -name run -o -name up \) -exec chmod +x {} +
RUN find /etc/cont-init.d -type f -exec chmod +x {} +

EXPOSE 8080
# Optionally expose Postgres for host access
EXPOSE 5432

ENTRYPOINT ["/init"]
