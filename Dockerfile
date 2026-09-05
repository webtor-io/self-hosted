ARG ALPINE_VER="3.22"
ARG S6_OVERLAY_VER="3.2.0.2"
ARG S6_VERBOSITY=1

# Component images are pinned by tag AND digest so Renovate can bump them
# one at a time and each component's provenance is fully reproducible.
# Nothing is compiled here any more. The Alpine base below and its apk
# packages are NOT pinned to a digest and will float to whatever `apk add`
# resolves at build time.
FROM ghcr.io/webtor-io/torrent-store:master@sha256:e17b7a32a88db4120d0de182649ac16040daab56eafac0b0e3a27a8a3dd55abf AS torrent-store
FROM ghcr.io/webtor-io/magnet2torrent:master@sha256:c28c6c94f6d976b831fca3a2632371bec61463f7062e7d75cf7f3091f8c64bb5 AS magnet2torrent
FROM ghcr.io/webtor-io/external-proxy:master@sha256:a7a267df98865d1e9e3c27cd47053db9ff9ed4b6b5e93fbf9a69d343d0c97c0f AS external-proxy
FROM ghcr.io/webtor-io/torrent-web-seeder:master@sha256:fefcdc90143ff9d572d0e09b0705034adb1d1ec4cd6659af5d64b88e11a2a211 AS torrent-web-seeder
FROM ghcr.io/webtor-io/torrent-web-seeder-cleaner:main@sha256:84ffc9c054094b3c2a077b8247dc74e3ae75b7ca965b473a8ada92143e1fdba0 AS torrent-web-seeder-cleaner
FROM ghcr.io/webtor-io/content-transcoder:master@sha256:f29e48b711f755920d999094f9cc0c35691707d005515b72dc8cbf8ceb6b6c79 AS content-transcoder
FROM ghcr.io/webtor-io/content-prober:master@sha256:7aef6155fddc2d2fda159d6566ef87d1c9ab9757bd2e8f15a8c6a7674b62a472 AS content-prober
FROM ghcr.io/webtor-io/torrent-archiver:master@sha256:aa7691ca6d90782176cbf3455a289501d5a9684b5ad703789bf8acdc912a6ac2 AS torrent-archiver
FROM ghcr.io/webtor-io/srt2vtt:master@sha256:7de27e2b93a980639685e8d29451f6a2c3c05219041c5c0e156e960e8138cac8 AS srt2vtt
FROM ghcr.io/webtor-io/torrent-http-proxy:master@sha256:66826afad417782cfffc1d91a60c5fde47cae048083a274f968e468d0f1d66ab AS torrent-http-proxy
FROM ghcr.io/webtor-io/rest-api:main@sha256:b626a44bf6706db929b7321f86d9126abc30f76a7b39b5187de2855fe35aee99 AS rest-api
FROM ghcr.io/webtor-io/web-ui:main@sha256:7578f9ae964b9efbcb7f2ff463e7e625f2b531d01e9065ea483795f31abbdf77 AS web-ui
FROM ghcr.io/webtor-io/nginx-vod:main@sha256:4d9aaa6ac3dc2e3e73bdf8afd47d4ffab0a932f22b91a4c8cdd7674290bd89dd AS nginx-vod
FROM ghcr.io/webtor-io/vault:main@sha256:0c130c5764c7f0c8377bd41bdf9545552098d702e49529d8acd65167d08acee8 AS vault

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
