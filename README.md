# Feedbot

A Discord bot that monitors RSS/Atom feeds and posts new entries to your server's channels. Subscriptions are managed via slash commands. Supports both real-time delivery (post as entries arrive) and digest delivery (batched on a schedule). Includes a JSON API and a minimal web UI for OAuth login and API token management.

## How it works

- Users with `MANAGE_CHANNELS` run `/feed add` in a Discord server to subscribe a channel to an RSS feed
- A background job polls feeds every 15 minutes using conditional `ETag`/`Last-Modified` GETs
- New entries are posted as rich Discord embeds — either immediately (real-time) or batched at a scheduled time (digest)
- Feed health is tracked; feeds that fail 20 consecutive polls are auto-disabled and surface in `/feed list`

## Slash commands

| Command | Description |
|---|---|
| `/feed add url:<url> channel:<#channel> mode:<realtime\|digest> [schedule:<hourly\|every_6h\|every_12h\|daily\|weekly>] [at:<HH:MM>]` | Subscribe a channel to a feed |
| `/feed list` | List this server's subscriptions |
| `/feed remove <id>` | Remove a subscription |
| `/feed edit <id> [channel] [mode] [schedule] [at]` | Edit a subscription |
| `/feed config timezone <tz>` | Set the server's timezone for digest scheduling (IANA, e.g. `America/New_York`) |

Command access defaults to `MANAGE_CHANNELS`. Server admins can override this in Discord's Server Settings → Integrations.

## Stack

- **Rails 8** + **SQLite** (app data, SolidQueue, SolidCache — separate DB files)
- **SolidQueue** for background jobs, running in-process via the Puma plugin
- **Feedjira** for RSS/Atom parsing with ETag-aware conditional GETs
- **ONCE** for self-hosted deployment (single Docker container)

## Development setup

**Prerequisites:** Ruby 3.3+, Node (for Tailwind), SQLite3.

```sh
bundle install
bin/rails db:setup
bin/dev
```

The app runs on `http://localhost:3000`.

### Discord application setup

1. Create an application at [discord.com/developers](https://discord.com/developers/applications)
2. Under **Bot**, enable the bot and copy the token
3. Under **OAuth2**, add a redirect URI: `http://localhost:3000/auth/discord/callback`
4. Copy the application ID, public key, and OAuth client credentials

Create a `.env` file (or set these in your shell):

```
DISCORD_APP_ID=
DISCORD_PUBLIC_KEY=
DISCORD_BOT_TOKEN=
DISCORD_OAUTH_CLIENT_ID=
DISCORD_OAUTH_CLIENT_SECRET=
```

### Register slash commands

Run once after setup (and again after any command definition changes):

```sh
bin/rails feedbot:register_commands
```

### Receive Discord interactions locally

Discord must be able to reach your local server to deliver slash command payloads. Use a tunnel:

```sh
cloudflared tunnel --url http://localhost:3000
```

Then set the **Interactions Endpoint URL** in your Discord application to `https://<tunnel-url>/discord/interactions`. Discord sends a signed PING to verify — the app must respond with PONG before the URL saves.

## Testing

```sh
bin/rails test
```

Key coverage: Ed25519 signature verification, slash command dispatch, cron derivation across DST boundaries, entry upsert idempotency, delivery deduplication, poll backoff math.

## Deployment (ONCE)

Feedbot deploys as a single Docker container managed by [ONCE](https://github.com/basecamp/once).

### First deploy

On your VPS, install the app with your Discord credentials:

```sh
once install ghcr.io/tmatti/feedbot:latest \
  --host feedbot.example.com \
  --env DISCORD_APP_ID=... \
  --env DISCORD_PUBLIC_KEY=... \
  --env DISCORD_BOT_TOKEN=... \
  --env DISCORD_OAUTH_CLIENT_ID=... \
  --env DISCORD_OAUTH_CLIENT_SECRET=...
```

Then register slash commands:

```sh
once exec feedbot bin/rails feedbot:register_commands
```

Finally, set the **Interactions Endpoint URL** in your Discord application to `https://feedbot.example.com/discord/interactions`.

### Subsequent deploys

A GitHub Actions workflow (`.github/workflows/release.yml`) builds and pushes a new image to GHCR on every push to `main`. ONCE picks up updates automatically, or trigger one manually:

```sh
once update feedbot
```

### Env vars provided automatically by ONCE

`SECRET_KEY_BASE`, `DISABLE_SSL`, `NUM_CPUS`, and SMTP vars are injected by ONCE — you do not need to set them.

### Backups

`hooks/pre-backup` runs SQLite's online backup before each ONCE backup, producing a consistent snapshot without pausing the container. Backups are managed from the ONCE TUI (Settings → Backups).

## API

The JSON API lives at `/api/v1`. Authenticate with a bearer token minted from `/account` (after Discord OAuth login) or with the session cookie from the OAuth flow.

```
GET    /api/v1/servers
GET    /api/v1/servers/:id
PATCH  /api/v1/servers/:id
GET    /api/v1/servers/:id/subscriptions
POST   /api/v1/servers/:id/subscriptions
GET    /api/v1/subscriptions/:id
PATCH  /api/v1/subscriptions/:id
DELETE /api/v1/subscriptions/:id
GET    /api/v1/feeds/:id
GET    /api/v1/feeds/:id/entries
GET    /api/v1/subscriptions/:id/deliveries
```

## Architecture notes

- **No gateway connection.** The bot uses Discord's HTTP Interactions endpoint only — no persistent WebSocket. All behavior is driven by incoming requests and background jobs.
- **Single process.** SolidQueue runs inside Puma via `plugin :solid_queue` so the Docker container has one process tree.
- **Delivery ledger.** Every `(subscription, entry)` pair gets a `Delivery` row. This is how the bot tracks what has been posted, handles retry, and prevents double-posting regardless of poll timing.
- **Digest scheduling.** Each digest subscription stores a `next_run_at` timestamp computed from its cron expression (via `fugit`) evaluated in the server's timezone. A job ticks every minute and fans out delivery for any subscriptions that are due.
