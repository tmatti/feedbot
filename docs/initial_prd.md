# Feedbot — Discord RSS Bot

## Context

Build a Discord bot that monitors RSS/Atom feeds and posts new entries to configured Discord servers/channels, plus a management API. Users add subscriptions via slash commands; each subscription is bound to one Discord channel and runs in either real-time or digest mode. Hosting is a self-managed VPS (or any Docker-capable Linux box) provisioned with **ONCE**. Subscriptions are server-scoped and managed by Discord users with `MANAGE_CHANNELS`. Frontend is intentionally minimal (just Discord OAuth + token minting) because the slash commands are the primary UX.

The bot uses Discord's HTTP Interactions endpoint (no persistent gateway connection), so the entire system is request/response Rails — one Docker container, one process tree.

A note on naming: Discord's API JSON uses the legacy term "guild" for what users see as a "Server" in Discord's UI. We use `Server` throughout our domain model and only say "guild" when literally referring to a Discord API field.

## Tech stack

- **Rails 8** (API + minimal HTML for OAuth)
- **SQLite** as the only datastore (app data, SolidQueue, SolidCache) — Rails 8's default, well-suited to this volume and pairs cleanly with ONCE's backup hooks
- **SolidQueue** for jobs and recurring tasks, run in-process via Puma plugin (one container, no separate worker role)
- **Feedjira** for RSS/Atom parsing
- **Faraday** for HTTP (used by Feedjira and our Discord REST client)
- **fugit** for cron parsing / `next_run_at` computation
- **ed25519** gem for verifying Discord interaction signatures (we roll our own thin Discord HTTP interactions handler — no full-fat Discord library needed)
- **ONCE** for deployment (Docker image + env vars + automatic backups + healthcheck)
- **Tailwind** for the OAuth/token UI

## Architecture overview

```
                          ┌────────────────────────┐
   Discord (slash cmd) ──▶│ POST /discord/interactions │  (Ed25519-verified)
                          │ Discord::InteractionsController │
                          └────────────┬────────────┘
                                       │ replies / enqueues
                                       ▼
                          ┌────────────────────────┐
                          │ SQLite: Server, Feed,  │
                          │ Subscription, Entry,   │
                          │ Delivery, ApiToken     │
                          └────────────┬───────────┘
                                       ▲
                                       │
   SolidQueue recurring (in-Puma):     │
   • PollFeedsJob  (every 15m) ────────┤
   • DispatchDueDigestsJob (1m)────────┘
                                       │
                                       ▼
                          ┌────────────────────────┐
   Discord REST API ◀─────│ PostDeliveryJob /      │
                          │ PostDigestJob          │
                          └────────────────────────┘

   Browser ──▶ /login ──▶ Discord OAuth ──▶ /callback ──▶ /account (mint API tokens)
   Programmatic ──▶ /api/v1/* with `Authorization: Bearer <token>`
```

## Data model

```
servers
  id (bigint pk)
  discord_id (bigint, unique)         -- Discord guild snowflake (the API's "guild_id")
  name (string)                       -- cached from Discord
  timezone (string, default 'UTC')    -- for digest cron evaluation
  created_at, updated_at

feeds  (one per unique URL across all servers; reused across subscriptions)
  id (bigint pk)
  url (string, unique)                -- normalized
  canonical_url (string)              -- after redirects
  title (string, nullable)
  etag (string, nullable)
  last_modified (string, nullable)
  last_polled_at (datetime, nullable)
  next_poll_at (datetime, nullable, indexed)   -- for backoff
  consecutive_failures (int, default 0)
  last_error (string, nullable)
  status (string: 'active'|'disabled', default 'active')
  created_at, updated_at

subscriptions
  id (bigint pk)
  server_id (fk → servers, indexed)
  feed_id (fk → feeds, indexed)
  discord_channel_id (bigint)         -- Discord channel snowflake
  created_by_discord_user_id (bigint) -- audit
  mode (string: 'realtime'|'digest')
  schedule_kind (string, nullable)    -- hourly|every_6h|every_12h|daily|weekly
  schedule_time (string, nullable)    -- 'HH:MM' for daily/weekly
  schedule_cron (string, nullable)    -- canonical cron derived from kind+time
  next_run_at (datetime, nullable, indexed) -- for digest dispatcher
  status (string: 'active'|'disabled', default 'active')
  created_at, updated_at
  unique(server_id, feed_id, discord_channel_id)

entries  (one row per (feed_id, guid))
  id (bigint pk)
  feed_id (fk, indexed)
  guid (string)
  url (string)
  title (string)
  summary (text, nullable)
  image_url (string, nullable)
  published_at (datetime, indexed)
  created_at
  unique(feed_id, guid)

deliveries  (the "did we post entry E to subscription S?" ledger)
  id (bigint pk)
  subscription_id (fk, indexed)
  entry_id (fk, indexed)
  posted_at (datetime, nullable)
  discord_message_id (bigint, nullable)
  skipped (boolean, default false)    -- true for backfill-suppressed entries on /feed add
  error (string, nullable)
  created_at, updated_at
  unique(subscription_id, entry_id)

api_tokens  (per-server bearer tokens minted from the OAuth UI)
  id (bigint pk)
  server_id (fk, indexed)
  name (string)                       -- user-supplied label
  token_digest (string, unique)       -- SHA-256, raw shown once on mint
  created_by_discord_user_id (bigint)
  last_used_at (datetime, nullable)
  revoked_at (datetime, nullable)
  created_at, updated_at

users  (only for OAuth UI sessions)
  id (bigint pk)
  discord_id (bigint, unique)
  username (string)
  avatar (string, nullable)
  created_at, updated_at
```

Schedule cron is derived in a method on `Subscription` (e.g. `Subscription#derived_cron`), not a separate service. SolidQueue and SolidCache use their own SQLite databases (Rails 8's standard multi-DB setup) so neither contends with the app data.

## Discord interactions surface

All commands are slash commands registered with `default_member_permissions = MANAGE_CHANNELS`. Server admins can override via Discord's native Server Settings → Integrations. Auto-disabled feeds surface in `/feed list` only — recovery is `/feed remove` then `/feed add`.

- `/feed add url:<url> channel:<#channel> mode:<realtime|digest> [schedule:<hourly|every_6h|every_12h|daily|weekly>] [at:<HH:MM>]`
  - Validates URL, fetches once (via `Feeds::Fetcher`), parses with Feedjira, upserts feed + entries.
  - Posts the **latest 1 entry** as confirmation; inserts `Delivery(posted_at: now)` for it; inserts `Delivery(skipped: true)` for all other currently-known entries on this sub. Future polls only deliver entries newer than the add.
  - For digest, sets `next_run_at` from `Subscription#derived_cron` evaluated in the server's timezone (via `fugit`).
- `/feed list` — paginated embed of the server's subs (feed title, channel, mode, schedule, status).
- `/feed remove <id>` — autocompleted from this server's active subs.
- `/feed edit <id> [channel] [mode] [schedule] [at]` — partial update; recomputes `schedule_cron` and `next_run_at` when schedule fields change.
- `/feed config timezone <tz>` — server-level IANA timezone; recomputes `next_run_at` for all digest subs.

Implementation:

- `Discord::InteractionsController#create` verifies `X-Signature-Ed25519` + `X-Signature-Timestamp` against the app's public key and dispatches by `data.name` to a small handler PORO. Handlers reach AR directly (`Subscription.create!(...)`, `subscription.update!(...)`) — no `Subscriptions::Create` service layer.
- PING (type 1) returns PONG. Slow commands (e.g. `/feed add` does a network fetch) respond with type 5 (deferred) and enqueue `RespondToInteractionJob` to PATCH the original response. Fast lookups reply synchronously with type 4.
- Slash command registration: `bin/rails feedbot:register_commands` (one-time rake task hitting `PUT /applications/{app_id}/commands`).

## Job pipeline

`config/recurring.yml`:
```yaml
production:
  poll_feeds:
    class: PollFeedsJob
    schedule: every 15 minutes
  dispatch_due_digests:
    class: DispatchDueDigestsJob
    schedule: every 1 minute
```

SolidQueue runs inside Puma via the `solid_queue` Puma plugin (`config/puma.rb`: `plugin :solid_queue`), so the container has one process tree.

- **PollFeedsJob**: selects `Feed.active.where('next_poll_at IS NULL OR next_poll_at <= ?', Time.current)` and enqueues `PollFeedJob` for each.
- **PollFeedJob(feed_id)**: uses `Feeds::Fetcher` (conditional GET with stored ETag/Last-Modified) and `Feeds::Parser` (Feedjira wrapper that upserts entries by `(feed_id, guid)`). For each new entry, enqueues `PostDeliveryJob` for every realtime sub on the feed; digest subs pick it up at their `next_run_at`. On error: `consecutive_failures += 1`, backoff `next_poll_at` at 5→15→60→240 min increments. After 20 consecutive failures → `status = 'disabled'`.
- **DispatchDueDigestsJob**: selects `Subscription.where(mode: 'digest', status: 'active').where('next_run_at <= ?', Time.current)`. For each sub: find undelivered entries (no `Delivery` row for this sub), enqueue `PostDigestJob`, advance `next_run_at` via `fugit`.
- **PostDeliveryJob(sub_id, entry_id)**: builds 1 embed via `Discord::EmbedBuilder`, POSTs via `Discord::RestClient`, writes `Delivery`. On 10003/50001 (channel gone/no access), disables the sub. On 429, retries after `Retry-After`.
- **PostDigestJob(sub_id, entry_ids[])**: sorts entries by `published_at`, chunks into ≤10 embeds per message, POSTs sequentially, writes `Delivery` rows. Channel errors mark deliveries with `error:`.

Embed shape: title (linked), description (summary truncated ~300 chars), author = feed title, timestamp = `published_at`, optional thumbnail.

## API surface (`/api/v1`)

Auth: `Authorization: Bearer <token>` — either a per-server API token (scoped to that server) or a session-derived token from OAuth (scoped to all servers the user has `MANAGE_CHANNELS` in).

```
GET    /api/v1/servers
GET    /api/v1/servers/:id
PATCH  /api/v1/servers/:id                     -- update timezone
GET    /api/v1/servers/:id/subscriptions
POST   /api/v1/servers/:id/subscriptions
GET    /api/v1/subscriptions/:id
PATCH  /api/v1/subscriptions/:id
DELETE /api/v1/subscriptions/:id
GET    /api/v1/feeds/:id
GET    /api/v1/feeds/:id/entries?limit=&before=
GET    /api/v1/subscriptions/:id/deliveries?limit=
```

Controllers reach AR directly. Validations live on the models (`Subscription` validates URL presence, mode/schedule consistency, channel format). The slash command handlers and the API controllers both call the same model methods — no shared service-object layer between them.

## OAuth UI

Minimal server-rendered ERB + Tailwind:

- `GET /login` — redirects to Discord OAuth (`identify guilds` scopes).
- `GET /auth/discord/callback` — exchanges code, upserts `User`, sets session cookie.
- `GET /account` — lists servers where user has `MANAGE_CHANNELS` and the bot is installed (intersection of Discord's `/users/@me/guilds` response and our `Server` table). Per server: API token list, mint form, revoke buttons. Raw token shown once on mint.
- `DELETE /logout`

Server-permission check runs against Discord's `/users/@me/guilds` response (`permissions` field) at request time with a 60-second cache keyed by `(user_id, server_id)`.

## Project structure

```
app/
  controllers/
    discord/
      interactions_controller.rb       # Ed25519 verify + dispatch
    auth/discord_controller.rb         # OAuth callback
    account_controller.rb              # token mint/revoke UI
    api/v1/
      base_controller.rb               # bearer auth, scope resolution
      servers_controller.rb
      subscriptions_controller.rb
      feeds_controller.rb
  jobs/
    poll_feeds_job.rb
    poll_feed_job.rb
    dispatch_due_digests_job.rb
    post_delivery_job.rb
    post_digest_job.rb
    respond_to_interaction_job.rb
  models/
    server.rb       # has_many :subscriptions, :api_tokens
    subscription.rb # belongs_to :server, :feed; #derived_cron, #compute_next_run_at!
    feed.rb         # has_many :entries, :subscriptions; #note_failure!, #note_success!
    entry.rb        # belongs_to :feed
    delivery.rb     # belongs_to :subscription, :entry
    api_token.rb    # belongs_to :server; .authenticate(raw)
    user.rb         # OAuth identity
  lib/feedbot/discord/
    signature_verifier.rb              # Ed25519 verifier (stateless)
    rest_client.rb                     # Faraday wrapper for discord.com/api/v10
    interactions/
      dispatcher.rb                    # routes interaction → handler
      feed_add.rb feed_list.rb feed_remove.rb feed_edit.rb feed_config.rb
    embed_builder.rb                   # Entry → Discord embed hash
  lib/feedbot/feeds/
    fetcher.rb                         # conditional GET, ETag/Last-Modified
    parser.rb                          # Feedjira wrapper + entry upsert
config/
  recurring.yml
  puma.rb                              # plugin :solid_queue
lib/tasks/
  feedbot.rake                         # register_commands
hooks/
  pre-backup                           # SQLite online-backup script for ONCE
```

## Deploy (ONCE)

ONCE installs and supervises a Docker image. Requirements the image must satisfy (per the ONCE README):

- HTTP on port 80
- Healthcheck endpoint at `/up` (Rails 8 ships this by default)
- All persistent data under `/storage` (ONCE also mounts the same volume at `/rails/storage` for Rails compatibility)
- Optional `/hooks/pre-backup` for safe SQLite snapshots

Concretely:

- The Rails 8 default Dockerfile is essentially compatible. Adjust to bind Puma to port 80 and store SQLite databases in `/rails/storage`:
  - `DATABASE_URL=sqlite3:/rails/storage/production.sqlite3`
  - `SOLID_QUEUE_DATABASE_URL=sqlite3:/rails/storage/queue.sqlite3`
  - `SOLID_CACHE_DATABASE_URL=sqlite3:/rails/storage/cache.sqlite3`
- `hooks/pre-backup` runs `sqlite3 /rails/storage/production.sqlite3 ".backup '/rails/storage/backup/production.sqlite3'"` for each DB so ONCE copies a consistent snapshot. (Without the hook ONCE briefly pauses the container during backup — also fine, just less smooth.)
- Slash command registration runs once after first install via `bin/rails feedbot:register_commands` from inside the container (`once exec <app> bin/rails feedbot:register_commands`).

Custom env vars (Discord credentials) are set at install time via ONCE's CLI (`once install <image> --env KEY=VALUE`, repeatable) or the TUI's Settings → Environment screen — both are first-class even though the README doesn't surface them. Required:

- `DISCORD_APP_ID`
- `DISCORD_PUBLIC_KEY`
- `DISCORD_BOT_TOKEN`
- `DISCORD_OAUTH_CLIENT_ID`
- `DISCORD_OAUTH_CLIENT_SECRET`

ONCE provides automatically: `SECRET_KEY_BASE`, `DISABLE_SSL`, SMTP_*, `NUM_CPUS`. Set Discord application "Interactions Endpoint URL" to `https://<host>/discord/interactions` after the install completes (Discord verifies by sending a signed PING — the controller must respond with PONG before the URL can be saved).

### CI / image publishing

ONCE pulls from a Docker registry — it does not accept a pushed binary. The dev workflow is:

1. **Build + push in CI.** A GitHub Actions workflow on push to `main` builds the image and pushes to GitHub Container Registry (GHCR):

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          push: true
          tags: ghcr.io/tmatti/feedbot:latest
```

2. **ONCE auto-updates** on its own schedule, or you trigger manually:
   ```sh
   once update feedbot
   ```

3. **First install** (one-time, run on the VPS):
   ```sh
   once install ghcr.io/tmatti/feedbot:latest \
     --host feedbot.example.com \
     --env DISCORD_APP_ID=... \
     --env DISCORD_PUBLIC_KEY=... \
     --env DISCORD_BOT_TOKEN=... \
     --env DISCORD_OAUTH_CLIENT_ID=... \
     --env DISCORD_OAUTH_CLIENT_SECRET=...
   ```

4. **Register slash commands** after the first install:
   ```sh
   once exec feedbot bin/rails feedbot:register_commands
   ```

No `config/deploy.yml`, no Kamal, no `kamal deploy`. Deployments are image publishes; ONCE handles the rest.

## Verification

1. `bin/rails db:setup && bin/rails feedbot:register_commands` (locally) — slash commands appear in your test server.
2. `bin/rails server` + a tunnel (e.g. `cloudflared`) → set as Discord interactions endpoint, confirm PING/PONG.
3. `/feed add url:https://news.ycombinator.com/rss channel:#test mode:realtime` → latest HN entry posts immediately.
4. Wait 15 min (or call `PollFeedsJob.perform_now` in console) → new entries flow into `#test`.
5. `/feed add url:<feed> channel:#test mode:digest schedule:hourly at:00` → at the next hour boundary a chunked-embed digest arrives.
6. `/feed list` → both subs visible with correct status.
7. `/feed config timezone America/Los_Angeles` → `next_run_at` recomputes (verify in console).
8. Mint a bearer token via `/account`, hit `GET /api/v1/servers` → returns the server.
9. Simulate 20 consecutive poll failures → feed marked `disabled`, surfaced in `/feed list`.
10. Test suite covers: Ed25519 signature verification (valid + tampered), interaction dispatch routing, `Subscription#derived_cron` across DST boundaries, entry upsert idempotency, delivery dedup, backoff math.
11. ONCE-specific smoke test: install the image to a throwaway VPS, set the five Discord env vars via `--env`, point a domain at it, trigger a manual ONCE backup → confirm the snapshot under `/storage/backup` contains a complete copy of `production.sqlite3`.

## Design decisions

1. Discord HTTP Interactions only — no gateway/WebSocket connection.
2. Deploy via **ONCE** (single Docker container, port 80, `/up` healthcheck, data in `/storage`). Custom env vars via `once install --env`.
3. **SQLite** as the only datastore (app data, SolidQueue, SolidCache, all separate SQLite files).
4. Domain model uses **`Server`** (mirroring Discord's UI). "Guild" appears only when referencing the literal Discord API field name.
5. Server-scoped subscriptions; one channel per subscription.
6. Hybrid delivery — per-subscription `realtime` or `digest` mode.
7. Schedules: friendly enum (`hourly` / `every_6h` / `every_12h` / `daily` / `weekly`) + optional `at HH:MM`, stored as cron, evaluated in a per-server IANA timezone.
8. Persisted `Entry` and `Delivery` rows — no watermark-only dedup.
9. SolidQueue runs **in-Puma** (single process tree) with two recurring tasks; digest dispatch via `next_run_at` tick-and-scan using fugit.
10. `/feed add` posts the latest 1 entry as confirmation; all other current entries skipped for that sub.
11. Slash command permissions via Discord-native `default_member_permissions = MANAGE_CHANNELS`.
12. API auth: Discord OAuth session (UI) + per-server bearer tokens minted from the account page.
13. Posts are rich Discord embeds; digests pack ≤10 embeds/message, chunked for overflow.
14. Feed polling: 15-minute global cadence, ETag/Last-Modified conditional GETs.
15. Failure handling: exponential backoff (5→15→60→240 min), auto-disable after 20 consecutive failures, recovery via remove + re-add.
16. No entry/delivery retention policy — keep everything forever.
17. v1 slash commands: `add`, `list`, `remove`, `edit`, `config timezone` only.
18. **Service objects only where they wrap external concerns**: `Discord::SignatureVerifier`, `Discord::RestClient`, `Feeds::Fetcher`, `Feeds::Parser`, `Discord::EmbedBuilder`. Subscription/feed CRUD lives directly on the models, called from controllers and slash command handlers.
