# Webtor, self-hosted

This is the self-hosted version of [webtor.io](https://webtor.io), implemented as an all-in-one Docker image.

## Features

- **Direct Download Link (DDL):** Select any file inside a torrent and download it directly.
- **Instant Video and Audio Streaming:** Choose a video or audio file inside a torrent and start streaming immediately without needing to download it first.  
  **Supported Formats:**
   - **Video:** `avi`, `mkv`, `mp4`, `webm`, `m4v`, `ts`, `vob`
   - **Audio:** `mp3`, `wav`, `ogg`, `flac`, `m4a`
- **Download Entire Torrent as a ZIP Archive:** Download your torrent as a ZIP archive on-the-fly while preserving the original directory structure, without requiring a torrent client.
- **Personal Library:** Organize your own collection by adding torrents to your account. Movies and series will be detected automatically!
- **Subtitles from OpenSubtitles:** Matching subtitle tracks are found and offered in the player automatically (needs a free OpenSubtitles API key, see "Configuring OpenSubtitles").
- **AI subtitles:** Translate subtitle tracks -- embedded, uploaded or found on OpenSubtitles -- into your language on the fly, right in the player (needs an AI API key, see "Configuring AI features").
- **Stremio integration** Just install the addon using the link from profile and start watching your library on TV with Stremio.
- **Developer-friendly** With the [SDK](https://github.com/webtor-io/embed-sdk-js) you can provide your users with the ability to watch torrent-videos online on your website.

## Quick Setup

1. [Install Docker](https://docs.docker.com/get-docker/).
2. Start your Webtor instance with the following command:
   ```bash
   docker run -d -p 8080:8080 -v data:/data -v pgdata:/pgdata -v storage:/storage --name webtor --restart=always ghcr.io/webtor-io/self-hosted:latest
   ```
3. Access the UI at <http://localhost:8080>.
4. You're all set!

You can run your Webtor instance on [ElfHosted](https://store.elfhosted.com/product/webtor/elf/10433/)!

## Supported Platforms

The image is published for `linux/amd64` and `linux/arm64`, so it runs on x86
servers as well as Apple Silicon, 64-bit ARM boards and ARM NAS devices. Docker
picks the right variant automatically — the command above is the same on every
platform. 32-bit ARM (`armv7`) is not supported.

## Administrator Password

By default the instance is open: anyone who can reach it has full access. Set a
password from the profile page, or start the container with one:

```bash
docker run -e ADMIN_PASSWORD=your-password -d -p 8080:8080 -v data:/data -v pgdata:/pgdata -v storage:/storage \
  --name webtor --restart=always ghcr.io/webtor-io/self-hosted:latest
```

`ADMIN_PASSWORD` overrides whatever password was set from the profile, which
also makes it the way back in if you forget it. To change the password without
putting it on the command line, source the environment the container's own
services run with first — `web-ui` isn't started under it by `docker exec`,
so a bare invocation connects to Postgres with the wrong defaults
(`PG_USER=webhook`, `PG_DATABASE=webhook`, no password) instead of the
`app`/`app` role the embedded database actually created:

```bash
docker exec webtor sh -c 'set -a; . /etc/webtor/common.env; cd /app/web-ui && ./web-ui admin set-password <new-password>'
```

Once a password is set, the web interface requires authentication for every
page (`ONLY_AUTHORIZED=true`, the default) — a visitor without a valid session
is redirected to `/login` instead of getting read access. Set
`ONLY_AUTHORIZED=false` to turn that off and fall back to the old behavior:
pages stay reachable without logging in, and only actions that were already
password-gated (e.g. changing settings) still prompt for one.

Embedding is handled separately, because a third-party `<iframe>` has no
session with your instance — redirecting it to a login form would only render
a broken player. Which sites may embed is decided by the embed domain list on
your profile page: add a domain there and the player works on it. A site that
is not on the list shows a short "not authorized" message inside the player
instead. Your own domain, `localhost` and `127.0.0.1` are always on the list.
To let any site embed from your instance, set `EMBED_ONLY_AUTHORIZED=false`.

Embedding on another site — and `localhost` and `127.0.0.1` count as
different sites — needs the instance served over https with
`DOMAIN=https://…` (see [Setting a Custom Domain](#setting-a-custom-domain)).
Over plain http the browser keeps no session in a cross-site frame, so the
player there cannot start.

## API Access

The REST API (`rest-api`) is not exposed publicly — nginx no longer proxies
`/rest-api/`. It still runs inside the container, but only web-ui's own
`/api/v1` can reach it, and `/api/v1` requires an API key.

To get a key: open the profile page in a browser (this requires being logged
in if `ADMIN_PASSWORD`/`ONLY_AUTHORIZED` are in effect) and generate an API
credential there. Then call `/api/v1` with it:

```bash
curl -H "Authorization: Bearer <your-api-key>" http://localhost:8080/api/v1/resource/<id>
```

`/api/v1` mirrors the old `/rest-api/` paths one for one (e.g.
`POST /resource`, `GET /resource/<id>`, `GET /resource/<id>/list`,
`GET /resource/<id>/export/<content_id>`) and returns the same response
shapes; only the host path prefix and the authentication requirement changed.

## Setting a Custom Domain

If you plan to access your instance from a different host or domain, set the `DOMAIN` environment variable to the address you open in the browser. Stream and download links are built from it, and its scheme decides how the login session is kept:

- **Plain http on your network** (`http://192.168.1.10:8080`, `http://nas.local:8080`): set `DOMAIN` to exactly that address.
  ```bash
  docker run -e DOMAIN=http://192.168.1.10:8080 -d -p 8080:8080 -v data:/data -v pgdata:/pgdata -v storage:/storage --name webtor --restart=always ghcr.io/webtor-io/self-hosted:latest
  ```
  Embedding the player on *other* sites needs https: browsers keep no session in a cross-site frame over plain http.
- **Behind an HTTPS reverse proxy**: set `DOMAIN=https://example.com` and always open the instance at that https address.
  ```bash
  docker run -e DOMAIN=https://example.com -d -p 8080:8080 -v data:/data -v pgdata:/pgdata -v storage:/storage --name webtor --restart=always ghcr.io/webtor-io/self-hosted:latest
  ```
  With an https `DOMAIN` the session cookie is `Secure`, so opening the same instance over plain `http://<ip>:8080` does not work: the browser drops the cookie and every action answers "CSRF token mismatch". Do not leave `DOMAIN` at an http value (such as the default) behind the proxy: links would point to that address, the session cookie would go without the `Secure` flag, and embedding on other sites would stay off.

## Setting Custom Port

```bash
docker run -e DOMAIN=http://localhost:8085 -d -p 8085:8080 -v data:/data -v pgdata:/pgdata -v storage:/storage --name webtor --restart=always ghcr.io/webtor-io/self-hosted:latest
```

## Configuring the Autocleaner

Webtor automatically cleans old data when there is insufficient space on the device. You can configure this behavior using the following variables:

```bash
CLEANER_FREE=35%
CLEANER_KEEP_FREE=25%
```

- `CLEANER_FREE` specifies how much space to clean when triggered.
- `CLEANER_KEEP_FREE` sets the threshold at which cleaning starts.

Both variables can be defined as percentages or as byte values (e.g., `10G` or `100M`).

## Configuring Database

By default Webtor uses an embedded PostgreSQL database. You can configure the database connection using the following environment variables:

- **USE_LOCALPG** - use built-in postgres (default: true)
- **PG_HOST** - host for postgres (default: localhost)
- **PG_PORT** - port for postgres (default: 5432)
- **PG_USER** - user for postgres (default: app)
- **PG_PASSWORD** - password for postgres (default: app)
- **PG_DATABASE** - database for postgres (default: app)

## Storage Layout

The container writes to three directories, and losing each one costs something
different:

- **`/data`** — the torrent download cache. Disposable: Webtor re-downloads
  whatever it needs from the swarm, so losing it costs time and bandwidth, not
  data.
- **`/pgdata`** — the embedded PostgreSQL database (accounts, your library,
  settings). Not disposable — there is nothing to re-fetch it from.
- **`/storage`** — the embedded S3 store. Part of it is a cache (posters,
  thumbnails) as disposable as `/data`; part of it is user-uploaded subtitles
  and content saved to Vault, both not disposable — nobody else has your
  copy, and Vault exists specifically so that content outlives the torrent's
  swarm. `/storage` grows as you save things to Vault; that growth is
  expected, not a leak — see [Configuring Vault](#configuring-vault).

Mount all three as real volumes:

```bash
docker run -d -p 8080:8080 -v data:/data -v pgdata:/pgdata -v storage:/storage \
  --name webtor --restart=always ghcr.io/webtor-io/self-hosted:latest
```

`/storage` specifically must be a **named Docker volume**, not a bind mount to
a host directory. The embedded S3 store keeps object metadata — etag, content
type, checksums, multipart state — in filesystem extended attributes, and bind
mounts from macOS and Windows (and some network filesystems on Linux) do not
support them. When that's the case the store logs a clear error and idles
instead of crash-looping — check `docker logs webtor` for a `[s3]`-prefixed
message if it never comes up.

If you ever need to copy `/storage` elsewhere (backup, moving to another
host), use a tool that preserves extended attributes — `rsync -X`, `cp -a`, or
`tar --xattrs`. A plain `cp -r`, or an archiver that drops xattrs, silently
throws away the object metadata the store depends on.

To move any of these paths, set `DATA_DIR`, `PGDATA_DIR` or `STORAGE_DIR` and
point your volume at the new path instead.

## Configuring S3 Storage

By default Webtor runs an embedded S3-compatible store (versitygw over a local
directory, see [Storage Layout](#storage-layout) above for the volume
requirements) for the poster cache, user-uploaded subtitles and thumbnails.
Credentials are generated on first boot and persisted, so they survive
container restarts. They live on the container's own filesystem, not in a
volume, so replacing the container — an image upgrade, for instance — mints a
new pair. Stored objects stay readable, but anything outside the instance that
held the old key needs the new one. Set `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` yourself to pin them across upgrades. You can configure it using the following environment
variables:

- **USE_LOCALS3** - use the built-in S3 store (default: true)
- **STORAGE_DIR** - directory backing the built-in S3 store (default: /storage)
- **AWS_ENDPOINT** - S3 endpoint (default: http://127.0.0.1:8099, the built-in store)
- **AWS_REGION** - S3 region (default: us-east-1)
- **AWS_NO_SSL** - disable TLS for the S3 endpoint (default: true)
- **AWS_ACCESS_KEY_ID** / **AWS_SECRET_ACCESS_KEY** - S3 credentials (auto-generated for the built-in store; set both to use your own or to point at an external S3)
- **AWS_POSTER_CACHE_BUCKET** - bucket for the poster cache (default: posters)
- **AWS_USER_SUBTITLE_BUCKET** - bucket for user-uploaded subtitles (default: subtitles)
- **AWS_THUMBNAIL_BUCKET** - bucket for thumbnails (default: thumbnails)

To use an external S3 instead of the built-in store, set `USE_LOCALS3=false`,
`AWS_ENDPOINT` and the credentials; the bucket variables above still apply —
plus `VAULT_AWS_BUCKET` (see [Configuring Vault](#configuring-vault) below) —
and point at buckets on that external store (which you must create yourself).

## Configuring Vault

Vault saves a torrent's content permanently into the built-in S3 store, so it
stays available for streaming and download from `/storage` even after the
torrent's swarm has gone quiet. Use "Save to Vault" on a torrent's page, or
open "My Vault" from your profile to see and manage what's saved.

Self-hosted instances have no subscription tiers, so Vault Points are
unlimited: there is no built-in cap on how much you can save. The real limit
is disk space — `/storage` grows as you save torrents, and that growth is
intended (see [Storage Layout](#storage-layout) above).

- **USE_VAULT** - enable the vault service and its scheduled cleanup jobs (default: true)
- **VAULT_PG_DATABASE** - database for Vault's own tables, separate from `PG_DATABASE` (default: vault)
- **VAULT_AWS_BUCKET** - bucket Vault stores content in (default: vault); with the built-in store this is a directory under `/storage`, with an external S3 (`USE_LOCALS3=false`) it is a bucket on that store which you must create yourself

Vault keeps its schema in its own database, never `PG_DATABASE` (web-ui's).
With the embedded PostgreSQL (`USE_LOCALPG=true`, the default) this database
is created for you alongside the main one. With `USE_LOCALPG=false` you must
create it yourself on your external PostgreSQL server before starting the
container — the default name is `vault`.

## Notifications

Webtor keeps an in-app notification feed — vault saves, vault content that is
expiring or has expired, transfer timeouts, and the like — behind the bell
icon in the navbar, with an unread-count badge next to it and the full list
at `/notifications`. The feed works with no configuration: every account
gets it for free, whether or not mail is set up.

Setting a notification email address is optional. The profile page's email
section only appears once SMTP is configured (see below) — without a mail
server there is no way to send the confirmation link an address needs before
it can be used. Once verified, matching notifications are mailed there too,
in addition to appearing in the feed.

The section is also hidden when an external identity provider owns the
address, since it is not this instance's to change. That does not happen in
the image as shipped, which configures no such provider; it is worth knowing
only if you point this instance at one yourself, in which case the missing
section is deliberate rather than a fault.

## Configuring Email Notifications (SMTP)

By default no SMTP server is configured, so no mail is ever sent —
notifications still show up in the feed, but nothing goes out by email.
Set these to enable delivery:

- **SMTP_HOST** - SMTP server host (default: unset; leave unset to keep email disabled)
- **SMTP_PORT** - SMTP server port (default: 465)
- **SMTP_USER** - SMTP username
- **SMTP_PASS** - SMTP password
- **SMTP_SECURE** - use implicit TLS when connecting to the SMTP server (default: true)
- **SMTP_FROM** - "From" address on outgoing mail (default: falls back to `SMTP_USER` if unset)

## Configuring content enrichment

Enrichment is what turns a release name into a title, a poster and a plot. It
asks each configured provider in turn; with none of them set, torrents keep
their raw names and no artwork.

- **TMDB_API_KEY** - key for The Movie Database. The primary provider: it is
  the only one that answers in languages other than English, so without it the
  interface shows English metadata whatever the chosen language.
- **OMDB_API_KEY** - key for OMDB API
- **KINOPOISK_UNOFFICIAL_API_KEY** - key for KinoPoisk Unofficial API

## Configuring OpenSubtitles

With an OpenSubtitles API key the player offers subtitle tracks found for the
exact file (by hash) in every language OpenSubtitles has. Like the enrichment
providers above, the key alone enables the feature; without it the player
only shows subtitles embedded in the file or uploaded by you. Search answers
and fetched subtitle files are cached in the embedded S3 and Redis, so a film
looked up once does not spend the key's quota again.

- **OSDB_API_KEY** - OpenSubtitles API key (default: unset, which disables
  the lookups). A free consumer key from
  <https://www.opensubtitles.com/en/consumers> is enough.
- **OSDB_USER** / **OSDB_PASS** - optional OpenSubtitles account login; a VIP
  account raises the daily download quota
- **OSDB_RATE** - requests per second against the OpenSubtitles API
  (default: 1)

## Configuring AI features

The features below are off by default. Each needs its own switch and an API
key for one of the two AI backends this image supports; setting a key alone
enables nothing. Calls are billed to that key, which is why each feature has
its own switch and recommendations have their own quota.

- **ANTHROPIC_API_KEY** - API key for the backend of the same name (default: unset)
- **OPENAI_API_KEY** - API key for the backend of the same name (default: unset)
- **OPENAI_BASE_URL** - API endpoint used with `OPENAI_API_KEY` (default: that
  backend's public endpoint)

One key serves all three features. With both set, `ANTHROPIC_API_KEY` is used
and `OPENAI_API_KEY` is ignored; a failing call never switches to the other
key. With neither set, every feature below is off whatever its switch says.
Each `*_MODEL` variable defaults to a model of the backend the key selects.
Model ids are not interchangeable between backends, so when you switch keys,
also clear any model id you set yourself.

AI enrichment is a fallback for the providers above: when TMDB, OMDB and
KinoPoisk all fail to recognise a release name, the model is asked to
normalise it into title/year candidates, which are then searched again through
those same providers. It never supplies metadata itself.

- **AI_ENRICH_ENABLED** - enable that fallback (default: false)
- **AI_ENRICH_MODEL** - model id (default: the selected backend's default)
- **AI_ENRICH_TIMEOUT_SECONDS** - timeout for one call (default: 30)
- **AI_ENRICH_MAX_CANDIDATES** - how many candidates to ask for (default: 3)

AI recommendations is the "describe what you want to watch" box on Discover.
With it off, or with no key, the section is not rendered at all.

- **AI_RECOMMENDATIONS_ENABLED** - enable the Discover section (default: false)
- **AI_RECOMMENDATIONS_MODEL** - model id, used for both tiers unless overridden
  (default: the selected backend's default)
- **AI_RECOMMENDATIONS_FREE_DAILY_QUOTA** - requests per day for a free account
  (default: 100 in this image; upstream web-ui defaults to 1). Without a claims
  provider every account is free-tier, so this is the quota everyone gets here;
  the default matches the paid cap and only serves as a backstop against a
  runaway client loop burning your API bill
- **AI_RECOMMENDATIONS_PAID_DAILY_QUOTA** - requests per day for a paid account
  (default: 100). No account is paid without a claims provider, so this has no
  effect in this image

AI subtitles is the "Translate to <your language>" track in the player's
subtitle picker. It translates the film's subtitle tracks -- embedded,
uploaded by you, or found through OpenSubtitles when that is configured
(see above). A film is translated progressively while you watch, the finished
translation is stored in the embedded S3, so any later viewing of the same
file and language is served from cache and costs nothing. The cache is kept
per model: a new model, or a switch to the other key (whose default model
differs), translates a file again; a new value of the same key keeps the cache.

- **SUBTITLE_TRANSLATE_ENABLED** - offer AI subtitle tracks (default: false)
- **SUBTITLE_TRANSLATE_MODEL** - model id (default: the selected backend's default)

With the switch on but no key, or a key set but the switch off, the track
is not offered and the `subtitle-translate` service explains in `docker logs`
which half is missing.

## Configring Stremio Addon Access

- **STREMIO_ADDON_USER_AGENT** - user agent to use for stremio addon
- **STREMIO_ADDON_PROXY** - proxy to use for stremio addon (like socks5://user:pass@host:port)

## Configuring Transcoding

- **DISABLE_VIDEO_TRANSCODING** - disables video transcoding (default: false)

## Disable UI Features

- **DISABLE_WEBDAV** - disables WebDAV interface (default: false)
- **DISABLE_EMBED** - disables embeds support (default: false)

## Other Custom Variables

- **WAIT_FOR_VPN** - waits for VPN to start (in case you are using Gluetun) (default: false)
- **REQUEST_URL_MAPPINGS** - custom mappings for request urls
- **EXTERNAL_PROXY_PRIVATE_NETWORK_ORIGINS** - comma-separated origins (`scheme://host[:port]`) that posters and subtitles may be fetched from even at a private or loopback address, such as a site on your LAN that embeds the player. Your own `DOMAIN` is always on the list; any other url is fetched from public addresses only, and a refused one is logged by `[external-proxy]` with the host and the reason (default: empty)
