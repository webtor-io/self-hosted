ARG ALPINE_VER="3.22"
ARG S6_OVERLAY_VER="3.2.0.2"
ARG S6_VERBOSITY=1

# Component images are pinned by tag AND digest so Renovate can bump them
# one at a time and each component's provenance is fully reproducible.
# Nothing is compiled here any more. The Alpine base below and its apk
# packages are NOT pinned to a digest and will float to whatever `apk add`
# resolves at build time.
FROM ghcr.io/webtor-io/torrent-store:master@sha256:a5a4d1340859c182c3cb1d17624a8142ad3a3da04c0f1ffc622f1b65a2c77cbc AS torrent-store
FROM ghcr.io/webtor-io/magnet2torrent:master@sha256:e79480a8159fdd7d145d424f1babe29cdaf24cbfad55dbe341f1159c2f6988af AS magnet2torrent
FROM ghcr.io/webtor-io/external-proxy:master@sha256:0467ae47db9ea0fece5f7861573a20097b4fec91fe09f13eb3c2b702196fb875 AS external-proxy
FROM ghcr.io/webtor-io/torrent-web-seeder:master@sha256:9cd58450ed5905a9b04236c1aee5e3dd9d683455d47085d202c30c531623a739 AS torrent-web-seeder
FROM ghcr.io/webtor-io/torrent-web-seeder-cleaner:main@sha256:d839cc3bb114ef1c1c2718bcbc8a490d75a4deca6207d569d23e6163485a78f8 AS torrent-web-seeder-cleaner
FROM ghcr.io/webtor-io/content-transcoder:master@sha256:73f594fdc559358a7f8a6279dd39f5b2c28d2f4eb1b00bf3d9c0959e9c42caea AS content-transcoder
FROM ghcr.io/webtor-io/content-prober:master@sha256:3bd658a5dfb8ab64bb6ffa46346b043436eb73473a3bf024dccc0fe333a9e400 AS content-prober
FROM ghcr.io/webtor-io/torrent-archiver:master@sha256:1c86ae45e6e23e3a82ce19f10b1672cc9cc4e14a549b2d714b0bfca56a678859 AS torrent-archiver
FROM ghcr.io/webtor-io/srt2vtt:master@sha256:084bc8b1810768242a6c986345f7b7e0e5b162921333b4114241605e3a6cfa86 AS srt2vtt
FROM ghcr.io/webtor-io/subtitle-translate:master@sha256:09c5590b171e81654ef640e2c0a2609b2578e5ed0a9f2849b8ffa9edf308fb98 AS subtitle-translate
FROM ghcr.io/webtor-io/video-info:master@sha256:e46649680fd6662c9f8050e1dcc3884fe81463e6457113000be0fae82870a881 AS video-info
FROM ghcr.io/webtor-io/torrent-http-proxy:master@sha256:aca64d423c0c1986a95472f97056071cc3eab89eaba71c1c04497111687c5d3d AS torrent-http-proxy
FROM ghcr.io/webtor-io/rest-api:main@sha256:7826489a3916a14b106aa0acbd8e4881dce407e4c23fd7c992181da63b7ae6aa AS rest-api
FROM ghcr.io/webtor-io/web-ui:main@sha256:bb00d84dac378c4b80b40820fab06bb813f182beb2c10eb7d8fd9fe850683e78 AS web-ui
FROM ghcr.io/webtor-io/nginx-vod:main@sha256:8a86365563d6f0312d9d542a56997375681b6ed808f3f2b0bc02fc280e422033 AS nginx-vod
FROM ghcr.io/webtor-io/vault:main@sha256:03015a0d542b4e5fb58e4853da0bec7cbdeb4997b87c50accf84ba15dacae823 AS vault

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
