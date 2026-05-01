# Feedbot — Discord RSS Bot

## Context

Build a Discord bot that monitors RSS/Atom feeds and posts new entries to configured server channels, plus a management API. Users add subscriptions via slash commands; each subscription is bound to one Discord channel and runs in either real-time or digest mode. Hosting is a self-managed VPS deployed via Kamal. Scope is server-scoped (guild-scoped) subscriptions managed by Discord users with `MANAGE_CHANNELS`. Frontend is intentionally minimal (just Discord OAuth + token minting) because the slash commands are the primary UX.

The bot uses Discord's HTTP Interactions endpoint (no persistent gateway connection), so the entire system is request/response Rails — no special long-lived processes beyond SolidQueue workers.

## Tech stack

- **Rails 8** (API + minimal HTML for OAuth)
- **PostgreSQL 16** as the only datastore (auth/state/queue/cache all on it)
- **SolidQueue** for jobs and recurring tasks (no Redis)
- **Feedjira** for RSS/Atom parsing
- **Faraday** for HTTP (used by Feedjira and our Discord REST client)
- **fugit** for cron parsing / `next_run_at` computation
- **ed25519** gem for verifying Discord interaction signatures (we roll our own thin Discord HTTP interactions handler — no full-fat Discord library needed)
- **Kamal 2** for VPS deployment
- **Tailwind** for the tiny OAuth/token UI (Rails default)

## Architecture overview

```
                          ┌───────────────────────┐
   Discord (slash cmd) ──▶│ POST /interactions     │  (Ed25519-verified)
                          │ InteractionsController│
                          └─────────┬─────────────┘
                                    │ enqueues / replies
                                    ▼
                          ┌───────────────────────┐
                          │ Postgres: Guild,Feed, │
                          │ Subscription, Entry,  │
                          │ Delivery, ApiToken    │
                          └─────────┬─────────────┘
                                    ▲
                                    │
   SolidQueue recurring:            │
   • PollFeedsJob   (every 15m) ────┤
   • DispatchDueDigestsJob (1m)─────┘
                                    │
                                    ▼
                          ┌───────────────────────┐
   Discord REST API ◀─────│ PostDeliveryJob       │
                          └───────────────────────┘

   Browser ──▶ /login ──▶ Discord OAuth ──▶ /callback ──▶ /account (mint API tokens)
   Programmatic ──▶ /api/v1/* with `Authorization: Bearer <token>`
```

## Data model

```
guilds
  id (bigserial pk)
  discord_id (bigint, unique)         -- Discord guild snowflake
  name (string)                       -- cached from Discord
  timezone (string, default 'UTC')    -- for digest cron evaluation
  created_at, updated_at

feeds  (one per unique URL across all guilds; reused across subscriptions)
  id (bigserial pk)
  url (string, unique, citext)
  canonical_url (string)              -- after redirects
  title (string, nullable)
  etag (string, nullable)
  last_modified (string, nullable)
  last_polled_at (timestamptz, nullable)
  next_poll_at (timestamptz, nullable, indexed)   -- for backoff
  consecutive_failures (int, default 0)
  last_error (string, nullable)
  status (enum: active|disabled, default active)
  created_at, updated_at

subscriptions
  id (bigserial pk)
  guild_id (fk)
  feed_id (fk)
  discord_channel_id (bigint)         -- Discord channel snowflake
  created_by_discord_user_id (bigint) -- audit
  mode (enum: realtime|digest)
  schedule_kind (enum: hourly|every_6h|every_12h|daily|weekly, nullable for realtime)
  schedule_time (string, nullable)    -- 'HH:MM' for daily/weekly
  schedule_cron (string, nullable)    -- canonical cron derived from kind+time
  next_run_at (timestamptz, nullable, indexed) -- for digest dispatcher
  status (enum: active|disabled, default active)
  created_at, updated_at
  unique(guild_id, feed_id, discord_channel_id)

entries  (one row per (feed_id, guid))
  id (bigserial pk)
  feed_id (fk, indexed)
  guid (string)
  url (string)
  title (string)
  summary (text, nullable)
  image_url (string, nullable)
  published_at (timestamptz, indexed)
  created_at
  unique(feed_id, guid)

deliveries  (the "did we post entry E to subscription S?" ledger)
  id (bigserial pk)
  subscription_id (fk, indexed)
  entry_id (fk, indexed)
  posted_at (timestamptz, nullable)
  discord_message_id (bigint, nullable)
  skipped (boolean, default false)    -- true for backfill-suppressed entries on /feed add
  error (string, nullable)
  created_at, updated_at
  unique(subscription_id, entry_id)

api_tokens  (per-guild bearer tokens minted from the OAuth UI)
  id (bigserial pk)
  guild_id (fk)
  name (string)                       -- user-supplied label
  token_digest (string, unique)       -- SHA-256, raw shown once on mint
  created_by_discord_user_id (bigint)
  last_used_at (timestamptz, nullable)
  revoked_at (timestamptz, nullable)
  created_at, updated_at

users  (only for OAuth UI sessions)
  id (bigserial pk)
  discord_id (bigint, unique)
  username (string)
  avatar (string, nullable)
  created_at, updated_at
```

## Discord interactions surface

All commands are slash commands registered with `default_member_permissions = MANAGE_CHANNELS`. Server admins can override via Discord's native Server Settings → Integrations. Auto-disabled feeds surface in `/feed list` only — recovery is `/feed remove` then `/feed add`.

- `/feed add url:<url> channel:<#channel> mode:<realtime|digest> [schedule:<hourly|every_6h|every_12h|daily|weekly>] [at:<HH:MM>]`
  - Validates URL, fetches once, parses with Feedjira, upserts feed + entries.
  - Posts the **latest 1 entry** as confirmation; inserts `Delivery(posted_at: now)` for it; inserts `Delivery(skipped: true)` for all other currently-known entries on this sub. Future polls only deliver entries newer than the add.
  - For digest, sets `next_run_at = Fugit::Cron.parse(cron).next_time(Time.now.in_time_zone(guild.timezone)).utc`.
- `/feed list` — paginated embed of guild's subs (feed title, channel, mode, schedule, status).
- `/feed remove <id>` — autocompleted from this guild's active subs.
- `/feed edit <id> [channel] [mode] [schedule] [at]` — partial update; recomputes `schedule_cron` and `next_run_at` when schedule fields change.
- `/feed config timezone <tz>` — guild-level IANA timezone; recomputes `next_run_at` for all digest subs.

Implementation notes:

- `app/controllers/discord/interactions_controller.rb`: verifies `X-Signature-Ed25519` + `X-Signature-Timestamp` against the app's public key, dispatches by `data.name` to a command handler.
- PING (type 1) returns PONG. Slow commands (e.g. `/feed add` which does an HTTP fetch) respond with type 5 (deferred) and enqueue `RespondToInteractionJob` to PATCH the original response. Fast lookups reply synchronously with type 4.
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

- **PollFeedsJob**: selects `Feed.active.where('next_poll_at IS NULL OR next_poll_at <= ?', now)`, enqueues `PollFeedJob` for each.
- **PollFeedJob(feed_id)**:
  - Conditional GET using stored `etag` / `last_modified`.
  - 304 → bump `last_polled_at`, reset failures, set `next_poll_at = now + 15.min`.
  - 200 → parse with Feedjira, upsert entries by `(feed_id, guid)`. For each new entry: enqueue `PostDeliveryJob` for each realtime sub; digest subs pick it up at `next_run_at`.
  - Error → `consecutive_failures += 1`, backoff `next_poll_at` at 5→15→60→240 min increments. After 20 failures → `status = :disabled`.
- **DispatchDueDigestsJob**: selects `Subscription.digest.active.where('next_run_at <= ?', now)`. For each sub: find undelivered entries (no Delivery row for this sub), enqueue `PostDigestJob`, advance `next_run_at` via fugit.
- **PostDeliveryJob(sub_id, entry_id)**: builds 1 embed, POSTs to Discord, writes `Delivery`. On 10003/50001 (channel gone), disables the sub. On 429, retries after `Retry-After`.
- **PostDigestJob(sub_id, entry_ids[])**: sorts entries by `published_at`, chunks into ≤10 embeds per message, POSTs sequentially, writes Delivery rows. Channel errors mark deliveries with `error:`.

Embed shape: title (linked), description (summary truncated ~300 chars), author = feed title, timestamp = `published_at`, optional thumbnail image.

## API surface (`/api/v1`)

Auth: `Authorization: Bearer <token>` — either a per-guild API token (scoped to that guild) or a session-derived token from OAuth (scoped to all guilds the user has `MANAGE_CHANNELS` in).

```
GET    /api/v1/guilds
GET    /api/v1/guilds/:id
PATCH  /api/v1/guilds/:id                     -- update timezone
GET    /api/v1/guilds/:id/subscriptions
POST   /api/v1/guilds/:id/subscriptions
GET    /api/v1/subscriptions/:id
PATCH  /api/v1/subscriptions/:id
DELETE /api/v1/subscriptions/:id
GET    /api/v1/feeds/:id
GET    /api/v1/feeds/:id/entries?limit=&before=
GET    /api/v1/subscriptions/:id/deliveries?limit=
```

Command handlers and API controllers share the same service objects (e.g. `Subscriptions::Create`).

## OAuth UI

Minimal server-rendered ERB + Tailwind, four routes:

- `GET  /login` — redirects to Discord OAuth (`identify guilds` scopes).
- `GET  /auth/discord/callback` — exchanges code, upserts `User`, sets session cookie.
- `GET  /account` — lists guilds where user has `MANAGE_CHANNELS` and bot is installed. Per guild: API token list, mint form, revoke buttons. Raw token shown once on mint.
- `DELETE /logout`

Guild permission check runs against Discord's `/users/@me/guilds` response (`permissions` field) at request time with a 60s cache keyed by `(user_id, guild_id)`.

## Project structure

```
app/
  controllers/
    discord/interactions_controller.rb
    auth/discord_controller.rb
    account_controller.rb
    api/v1/
      base_controller.rb
      guilds_controller.rb
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
    guild.rb  subscription.rb  feed.rb  entry.rb  delivery.rb  api_token.rb  user.rb
  services/
    discord/
      signature_verifier.rb
      rest_client.rb           # Faraday wrapper for discord.com/api/v10
      command_dispatcher.rb
      commands/
        feed_add.rb  feed_list.rb  feed_remove.rb  feed_edit.rb  feed_config.rb
      embed_builder.rb
    feeds/
      fetcher.rb               # conditional GET, ETag/Last-Modified handling
      parser.rb                # Feedjira wrapper + entry upsert
    subscriptions/
      create.rb  update.rb  destroy.rb
    schedules/
      cron_builder.rb          # (kind, time, tz) → cron string via fugit
config/
  recurring.yml
lib/tasks/
  feedbot.rake                 # register_commands
```

## Deploy (Kamal)

- **web** role: Rails puma server (interactions endpoint + OAuth UI + API).
- **worker** role: `bin/rails solid_queue:start`.
- **accessory**: Postgres (or external managed).
- Required env vars: `DISCORD_APP_ID`, `DISCORD_PUBLIC_KEY`, `DISCORD_BOT_TOKEN`, `DISCORD_OAUTH_CLIENT_ID`, `DISCORD_OAUTH_CLIENT_SECRET`, `RAILS_MASTER_KEY`, `DATABASE_URL`.
- Set Discord application "Interactions Endpoint URL" to `https://<host>/discord/interactions`. Discord verifies by sending a signed PING — the controller must respond with PONG before the URL can be saved.

## Verification

1. `bin/rails db:setup && bin/rails feedbot:register_commands` — confirm slash commands appear in your test guild.
2. `bin/rails server` + tunnel (e.g. `cloudflared`) → set as Discord interactions endpoint, confirm PING/PONG.
3. `/feed add url:https://news.ycombinator.com/rss channel:#test mode:realtime` → latest HN entry posts immediately.
4. Start `solid_queue`, wait 15 min (or call `PollFeedsJob.perform_now` in console) → new entries flow into `#test`.
5. `/feed add url:<feed> channel:#test mode:digest schedule:hourly at:00` → at the next hour boundary a chunked-embed digest arrives.
6. `/feed list` → both subs visible with correct status.
7. `/feed config timezone America/Los_Angeles` → `next_run_at` recomputes (verify in console).
8. Mint a bearer token via `/account`, hit `GET /api/v1/guilds` → returns the guild.
9. Simulate 20 consecutive poll failures → feed marked `disabled`, surfaced in `/feed list`.
10. Test suite covers: Ed25519 signature verification (valid + tampered), command dispatch routing, `CronBuilder` across DST boundaries, entry upsert idempotency, delivery dedup, backoff math.

## Design decisions

1. Discord HTTP Interactions only — no gateway/WebSocket connection.
2. Kamal 2 on a self-managed VPS.
3. Server-scoped subscriptions; one channel per subscription.
4. Hybrid delivery — per-subscription `realtime` or `digest` mode.
5. Schedules: friendly enum (`hourly` / `every_6h` / `every_12h` / `daily` / `weekly`) + optional `at HH:MM`, stored as cron, evaluated in a per-guild IANA timezone.
6. Persisted `Entry` and `Delivery` rows — no watermark-only dedup.
7. SolidQueue + two recurring tasks; digest dispatch via `next_run_at` tick-and-scan using fugit.
8. `/feed add` posts the latest 1 entry as confirmation; all other current entries skipped for that sub.
9. Slash command permissions via Discord-native `default_member_permissions = MANAGE_CHANNELS`.
10. API auth: Discord OAuth session (for UI) + per-guild bearer tokens minted from the account page.
11. Posts are rich Discord embeds; digests pack ≤10 embeds/message, chunked for overflow.
12. Feed polling: 15-minute global cadence, ETag/Last-Modified conditional GETs.
13. Failure handling: exponential backoff (5→15→60→240 min), auto-disable after 20 consecutive failures, recovery via remove + re-add.
14. No entry/delivery retention policy — keep everything forever.
15. v1 slash commands: `add`, `list`, `remove`, `edit`, `config timezone` only.
