# Feedbot — Code Review Findings

**Reviewed:** 2026-06-09
**Scope:** Current implementation (`ef1a8a4`) vs. `docs/initial_prd.md`.
**Method:** Static review of all app/lib/config code plus two empirical checks (fugit timezone behaviour, Faraday redirect behaviour) run against the project's gems.

---

## TL;DR

The scaffolding closely follows the PRD's structure — models, jobs, slash-command handlers, the Ed25519 controller, the REST client, and the ONCE deploy hooks are all present and largely match the spec. **Realtime delivery is essentially complete.** However:

- **Digest mode is completely broken** — `Subscription#compute_next_run_at!` raises `ArgumentError` for every digest subscription (wrong fugit API usage). This takes out `/feed add … mode:digest`, `/feed edit`, and `/feed config timezone`.
- **Feeds that redirect (e.g. `http:` → `https:`) fail to fetch** — Faraday isn't configured to follow redirects, so a `301/302` raises `FetchError`.
- **The PRD's required test suite does not exist** (only `test/test_helper.rb`).
- Several smaller correctness and parity gaps (broken `/feed edit` autocomplete, wrong backup filenames, double failure-counting, `retry_job` misuse, dead `Server.upsert_from_discord!`).

---

## PRD coverage matrix

| PRD area | Status | Notes |
|---|---|---|
| Data model (5 tables, indexes, unique constraints) | ✅ Complete | `db/schema.rb` matches the PRD field-for-field. |
| Ed25519 signature verification | ✅ Complete | `signature_verifier.rb` + controller `before_action`. |
| Interactions dispatch (PING/command/autocomplete) | ⚠️ Partial | Edit autocomplete unhandled (Bug #4); unknown types return `nil`. |
| `/feed add` (defer + job, post latest 1, skip rest) | ⚠️ Partial | Realtime works; digest path raises (Bug #1). Redirects fail (Bug #2). |
| `/feed list` | ⚠️ Partial | No pagination; hard `limit(10)` (Gap #9). |
| `/feed remove` (+ autocomplete) | ✅ Complete | Works; autocomplete unfiltered but functional. |
| `/feed edit` | ⚠️ Partial | Works for realtime; digest recompute raises (Bug #1); autocomplete broken (Bug #4). |
| `/feed config timezone` | ❌ Broken | Recompute loop raises (Bug #1). |
| PollFeedsJob / PollFeedJob (conditional GET, backoff, auto-disable) | ⚠️ Partial | Backoff/disable logic correct; double-counts failures (Bug #5); redirects fail (Bug #2). |
| DispatchDueDigestsJob | ⚠️ Partial | Logic correct but depends on `next_run_at`, which is never set (Bug #1). |
| PostDeliveryJob | ⚠️ Partial | Works; `retry_job wait:` misuse (Bug #6); create race (Bug #7). |
| PostDigestJob (≤10 embeds, chunking) | ✅ Complete | Chunking + error ledger correct; blocking `sleep` on 429 (Low). |
| EmbedBuilder | ✅ Complete | Matches PRD embed shape. |
| `recurring.yml`, `puma.rb` plugin, SQLite multi-DB | ✅ Complete | As specified. |
| Slash-command registration rake task | ✅ Complete | `lib/tasks/feedbot.rake` correct. |
| ONCE deploy (port/`/up`/`/storage`/pre-backup) | ⚠️ Partial | Backup hook backs up wrong filenames (Bug #3); leftover Kamal/`deploy.yml` (Deviation #1). |
| Test suite (PRD §Verification #11) | ❌ Missing | No tests exist at all. |

---

## Bugs (by severity)

### 🔴 Critical

#### Bug #1 — Digest scheduling raises for every digest subscription
`app/models/subscription.rb:40-50`

```ruby
cron = Fugit.parse_cron(cron_str)
update!(..., next_run_at: cron.next_time(tz).to_t)
```

`Fugit::Cron#next_time(arg)` treats `arg` as the **"from" reference time**, not a timezone. Passing an `ActiveSupport::TimeZone` raises. Verified against the project's gems:

```
next_time(tz) RAISED: ArgumentError: Cannot turn #<ActiveSupport::TimeZone …> to a ::EtOrbi::EoTime instance
```

**Impact:** Every code path that computes a digest schedule blows up:
- `/feed add … mode:digest` → `RespondToInteractionJob` hits the generic `rescue`, replies "Something went wrong", then re-raises (job retries and fails again). **Digest subscriptions can't be created.**
- `/feed edit` with a schedule/mode change → raises.
- `/feed config timezone` → raises while looping over digest subs.

Because `next_run_at` is therefore never set, even if a row slipped through, `Subscription.due_digests` (`where("next_run_at <= ?", …)`) excludes `NULL`, so digests would never dispatch anyway. **Digest mode is entirely non-functional.**

**Fix:** Embed the timezone in the cron string and call `next_time` with no argument. Verified working:

```ruby
def derived_cron
  return nil unless mode == "digest" && schedule_kind.present?
  base =
    if CRON_MAP.key?(schedule_kind)
      CRON_MAP[schedule_kind]
    else
      time = schedule_time.presence || "09:00"
      hh, mm = time.split(":").map(&:to_i)
      day = schedule_kind == "weekly" ? "1" : "*"
      "#{mm} #{hh} * * #{day}"
    end
  "#{base} #{server.timezone}"          # e.g. "0 9 * * * America/New_York"
end

def compute_next_run_at!
  cron_str = derived_cron
  return unless cron_str
  update!(schedule_cron: cron_str, next_run_at: Fugit.parse_cron(cron_str).next_time.to_t)
end
```

(Note: this also makes the PRD's "DST-correct via fugit" requirement actually hold. Add the DST test the PRD asks for.)

---

### 🟠 High

#### Bug #2 — Redirecting feeds fail to fetch
`app/lib/feedbot/feeds/fetcher.rb:14-35, 45-49`

The Faraday connection has no redirect middleware, so a `301/302` falls through to the `else` branch and raises `FetchError "HTTP 301"`. Verified: `Faraday.new.get("http://github.com")` returns status `301`. HTTP→HTTPS redirects are extremely common for feed URLs, so many `/feed add` attempts will fail outright, and previously-working feeds that start redirecting will accumulate failures toward auto-disable.

This also defeats the PRD's `canonical_url` ("after redirects") intent — `response.env.url` only reflects redirects if they were followed.

**Fix:** add `faraday-follow_redirects` and `f.response :follow_redirects` to the connection (and to the REST client if needed).

#### Bug #3 — Pre-backup hook backs up non-existent DB files
`hooks/pre-backup:8` vs `config/database.yml:25-36`

The hook loops over `production`, `queue`, `cache` → `/storage/{production,queue,cache}.sqlite3`. But the actual production filenames are `production.sqlite3`, **`production_queue.sqlite3`**, and **`production_cache.sqlite3`** (relative `storage/`, per `database.yml`). So the queue and cache snapshots are silently skipped (`[ -f "$src" ]` is false), and the path prefix assumes the env-var layout from the PRD that the app doesn't actually use.

**Fix:** align the hook with `database.yml` (`production`, `production_queue`, `production_cache`), or switch `database.yml` to the `/storage/*.sqlite3` + `*_DATABASE_URL` layout the PRD's Deploy section describes (§210-212). Right now the PRD deploy section and the committed config disagree.

#### Bug #4 — `/feed edit` id autocomplete returns an invalid (nil) response
`app/lib/feedbot/discord/interactions/dispatcher.rb:29-34` + `lib/tasks/feedbot.rake:55`

The `edit` command registers `id` with `autocomplete: true`, but `dispatch_autocomplete` only handles `when "remove"`. When the user opens the `edit id` picker, the dispatcher returns `nil`, the controller renders `json: nil`, and Discord receives an invalid autocomplete response.

**Fix:** either drop `autocomplete: true` from the edit `id` option, or add `when "edit" then FeedRemove… ` (extract the shared choice-builder and route edit to it too).

---

### 🟡 Medium

#### Bug #5 — `PollFeedJob` double-counts failures and retries inconsistently
`app/jobs/poll_feed_job.rb:24-29`

`FetchError` is noted and swallowed (no retry — good). But the generic `rescue => e` both calls `note_failure!` **and** `raise`s, so SolidQueue retries the job; on retry it can `note_failure!` again. A feed that raises a non-`FetchError` (e.g. a Feedjira parse error) increments `consecutive_failures` faster than the intended 1-per-cycle and churns the backoff math the PRD specifies (5→15→60→240). Either don't raise after noting, or don't note before raising.

#### Bug #6 — `retry_job wait:` is passed an absolute `Time`
`app/jobs/post_delivery_job.rb:23-25`

```ruby
retry_at = Time.current + e.retry_after.seconds
retry_job wait: retry_at
```

`retry_job`'s `wait:` expects a **duration**; an absolute time belongs in `wait_until:`. As written the scheduled-at computation is wrong. Use `retry_job wait: e.retry_after.seconds` or `retry_job wait_until: retry_at`.

#### Bug #7 — Delivery create race can crash `PostDeliveryJob`
`app/jobs/post_delivery_job.rb:10,17`

The idempotency guard is a `Delivery.exists?(… skipped: false)` check followed by `Delivery.create!`. Two concurrent jobs for the same `(sub, entry)` both pass the check, and the second `create!` violates the unique index → unhandled `RecordNotUnique`. Use `find_or_create_by` / `create_or_find_by` and treat the conflict as success.

---

### 🟢 Low

- **Dead code:** `Server.upsert_from_discord!` (`server.rb:8-12`) is never called. Handlers use `find_or_create_by!` with `s.name = guild_id.to_s`, so **`servers.name` is always the numeric guild ID, never the real server name** the PRD says is "cached from Discord". Wire the upsert (and pass the guild name from the interaction payload's `guild` object) if the cached name matters.
- **`config/environments/production.rb:51`** connects only `:queue`; `solid_cache` relies on default wiring. Fine for now, but worth an explicit `connects_to` if cache contention appears.
- **`schedule_time` validation** (`subscription.rb:59-61`) requires zero-padded `HH:MM` and doesn't bound hours/minutes, so `"9:00"` is rejected and `"99:99"` is accepted (→ invalid cron). Tighten the regex (`\A([01]\d|2[0-3]):[0-5]\d\z`).
- **`FeedConfig` validation** (`feed_config.rb:17`) leans on a trailing `rescue false` with mixed `||`/`rescue` precedence — it happens to work but is fragile; prefer an explicit `valid_timezone?` helper.
- **`PostDigestJob` 429 handling** (`post_digest_job.rb:30-32`) calls `sleep`, blocking the worker thread for the full `Retry-After`. Acceptable at this scale but ties up a worker.
- **`EmbedBuilder`** sets no `color` (FeedList does); cosmetic.

---

## Deviations from the PRD (not bugs, but divergence)

1. **Kamal artifacts still present** — `config/deploy.yml`, `bin/kamal`, `.kamal/`. PRD §274 explicitly states "No `config/deploy.yml`, no Kamal." Leftover scaffold; harmless but contradicts the documented deploy model.
2. **DB file layout** — PRD §210-212 prescribes `/storage/*.sqlite3` via `*_DATABASE_URL`; the app uses Rails-default relative `storage/production*.sqlite3`. Pick one and make the backup hook + ONCE `/storage` mount consistent (see Bug #3).
3. **`/feed list` pagination** — PRD §123 says "paginated embed"; implementation is a static `limit(10)` with no paging controls.
4. **Autocomplete filtering** — `FeedRemove#autocomplete` returns the first 25 subs regardless of what the user has typed (ignores the focused option value). Functional but not true autocomplete.

---

## Missing vs. PRD §Verification

- **No automated tests.** PRD item #11 requires coverage of: Ed25519 verify (valid + tampered), dispatch routing (commands + autocomplete), `derived_cron` across DST, `at:` defaulting, entry-upsert idempotency, delivery dedup, and backoff math. Only `test/test_helper.rb` exists. Given Bug #1 and Bug #5, a `Subscription#compute_next_run_at!` test and a backoff test would have caught real defects.

---

## Suggested fix order

1. **Bug #1** (digest scheduling) — unblocks all of digest mode.
2. **Bug #2** (redirects) — unblocks a large fraction of real feeds.
3. **Bug #4** (edit autocomplete) and **Bug #3** (backup filenames) — small, user-visible / data-safety.
4. **Bugs #5–#7** — correctness hardening in the job layer.
5. Backfill the PRD-mandated test suite, starting with `compute_next_run_at!` (incl. a DST case) and the failure/backoff math.
