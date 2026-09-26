ARG ALPINE_VER="3.22"
ARG S6_OVERLAY_VER="3.2.0.2"
ARG S6_VERBOSITY=1

# Component images are pinned by tag AND digest so Renovate can bump them
# one at a time and each component's provenance is fully reproducible.
# Nothing is compiled here any more. The Alpine base below and its apk
# packages are NOT pinned to a digest and will float to whatever `apk add`
# resolves at build time.
FROM ghcr.io/webtor-io/torrent-store:master@sha256:e24879dbe0b2eeec56c32dac0334bcc48f78dd069c945e91b1039147e1a94c25 AS torrent-store
FROM ghcr.io/webtor-io/magnet2torrent:master@sha256:995def6c52f189b9afc6de1a6493330d8fc25797ca4cbba95f0d7e364ea56493 AS magnet2torrent
FROM ghcr.io/webtor-io/external-proxy:master@sha256:a7a267df98865d1e9e3c27cd47053db9ff9ed4b6b5e93fbf9a69d343d0c97c0f AS external-proxy
FROM ghcr.io/webtor-io/torrent-web-seeder:master@sha256:bc42d3829487b741a98cbf6f83725d75aebda281662c8ed796654dbebf056d7e AS torrent-web-seeder
FROM ghcr.io/webtor-io/torrent-web-seeder-cleaner:main@sha256:7b0e22c4091a152aacd78eb4cbe625d2c76da1a7757b689a8c589f43ba099343 AS torrent-web-seeder-cleaner
FROM ghcr.io/webtor-io/content-transcoder:master@sha256:dc86f81aebeae2bcb8c80c05c130d7cdc9587abb850f416d3f3f5f9c69ceddbd AS content-transcoder
FROM ghcr.io/webtor-io/content-prober:master@sha256:71c3ebeb578f42f3909f42655b963afe0be8f169e76a69ef7d82fb1b6c686cc7 AS content-prober
FROM ghcr.io/webtor-io/torrent-archiver:master@sha256:76196b2b4c9e84203111bcf8b95e53cf33ddfa949571a452d0b63aaf543ad339 AS torrent-archiver
FROM ghcr.io/webtor-io/srt2vtt:master@sha256:7de27e2b93a980639685e8d29451f6a2c3c05219041c5c0e156e960e8138cac8 AS srt2vtt
FROM ghcr.io/webtor-io/subtitle-translate:master@sha256:c823ac1475f91d924b3b0721d03b70cacd2904688742a43a5b8b3f889e56386e AS subtitle-translate
FROM ghcr.io/webtor-io/video-info:master@sha256:bf81075df9c09ac41aefd2abd1ca2d880855d051b75dca5f5bdc579a276acb8a AS video-info
FROM ghcr.io/webtor-io/torrent-http-proxy:master@sha256:dd06beb4b119cc573a7992ab158438066b98656a1a49eff801302064ca5793c7 AS torrent-http-proxy
FROM ghcr.io/webtor-io/rest-api:main@sha256:d6f44932cee9ecb41336736745287ab12ac86f069ed879cc2051010060adcecf AS rest-api
FROM ghcr.io/webtor-io/web-ui:main@sha256:ce12e211a39465a9cef83235efad1177002a4f5e015855bb406d642073b5740c AS web-ui
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
