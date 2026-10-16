# Software design document

## Purpose

mqttscope is a web explorer for one MQTT broker. It answers the questions I kept asking at a
broker: what is publishing right now and how often, what did a topic say an hour ago, what changed
between two payloads, how does a numeric field trend, which devices are online, and how is the
broker itself doing. It does this from a single process with a single broker connection, keeps a
bounded history in SQLite, and exposes everything over HTTP (JSON + Server-Sent Events) so the UI
and any other client see the same data.

## Architecture

One Ruby process (Puma, 4–16 threads, `config/puma.rb`) hosts a Roda application (`app.rb`) and a
few long-lived modules. Puma runs a single worker on purpose: the MQTT client, the bus subscribers
and the pruner live in memory and must be shared by every request.

| Component | File | Lifetime | Role |
|---|---|---|---|
| Ingest | `lib/ingest.rb` | once per process | the broker connection: supervised reader thread, backoff reconnect, publish with echo tagging, a ticker emitting `stats` events |
| TopicRegistry | `lib/topic_registry.rb` | reloadable | in-memory view of every topic seen: counts, rate rings, last payload, LRU-bounded by `max_topics` |
| Sampling | `lib/sampling.rb` | reloadable | decides whether a message is stored: dedup, then per-filter minimum interval (`sample_rules`) |
| Store | `lib/store.rb` | reloadable | all reads and writes to SQLite: record, history, search (FTS5), series, stats |
| Pruner | `lib/pruner.rb` | once per process | periodic retention by age and size |
| Bus | `lib/bus.rb` | once per process | in-process fan-out from Ingest to SSE subscribers, bounded in both directions |
| Differ | `lib/differ.rb` | reloadable, pure | payload classification, JSON-path and line diffs, numeric path discovery |
| Presence | `lib/presence.rb` | reloadable | derives devices and online timelines from status topics (`presence_rules`) |
| SettingsValidator | `lib/settings_validator.rb` | reloadable | validates `POST /api/settings` input |
| API | `routes/api.rb`, `routes/stream.rb` | reloadable | JSON endpoints and the SSE pump |
| Pages | `routes/pages.rb`, `views/`, `public/` | reloadable | the four HTML pages and their JS |
| Models | `models/` | reloadable | Sequel connection (`database.rb`), `Setting`, `Topic`, `Message` |

Modules talk through plain Ruby method calls documented in [`contracts.md`](contracts.md).
Browsers talk HTTP; the only push channel is SSE. There are no external dependencies beyond the
broker and the SQLite file.

The split between "once" and "reloadable" is what makes `rack-unreloader` safe in development:
stateful modules are required in `app.rb` before the reloader takes over, the rest is reloaded on
the next request after an edit (`config.ru` lists the reloadable constants).

## Data model and storage

SQLite (`DATABASE_PATH`, default `data/mqttscope.db`) in WAL mode with incremental auto-vacuum,
schema in `db/migrations/`:

- `settings(key, value)` — every runtime setting, read with `Setting.fetch(key, default)`.
- `topics(id, name, first_seen_ms, last_seen_ms, stored_count, retained)` — one row per topic that
  has ever had a stored message.
- `messages(id, topic_id, ts_ms, payload BLOB, size, retained, qos, origin, dup_count, truncated)` —
  the stored history, indexed by `(topic_id, ts_ms)` and `ts_ms`. `origin` is `broker` or `ui`;
  `dup_count` counts consecutive identical payloads collapsed into this row; `truncated` marks
  payloads cut at `max_payload_bytes`.
- `messages_fts` — an external-content FTS5 table over `payload`, kept in step by insert/delete
  triggers, with `secure-delete` so pruned payloads leave no trace in the index.

In memory: the TopicRegistry (every topic seen, stored or not, with a rate ring per topic), the
Sampling state (last stored payload digest and timestamp per topic), the Ingest echo table (recent
UI publishes awaiting their broker echo) and the Bus subscriber list. Each of these has a cap.

Timestamps are integer milliseconds since epoch everywhere; payloads are binary-safe strings and
are only interpreted (UTF-8, JSON) at the edges.

## Key flows

**Ingest.** Ingest opens one MQTT connection with the current `mqtt_*` settings and subscribes at
QoS 1 to each filter in `mqtt_subscriptions` (default `#` and `$SYS/#`). Per received packet, in
order: `TopicRegistry.touch` → `Sampling.store?` → if true `Store.record` (or `Store.bump_dup` on a
dedup hit) → `Bus.publish` of a `message` event, always, with `stored:` saying which. A first-seen
topic also emits a `topic` event; connection state changes emit `connection` events. If the client's
read queue grows past `ingest_max_backlog` the backlog is acked and dropped with a warning rather
than letting memory grow. On any error the reader thread sleeps through `reconnect_backoff_s` and
reconnects; `Ingest.reconnect!` (used after connection settings change) forces that path.

**Storage decision.** Sampling first drops a payload identical to the last stored one for that
topic (`dedup_enabled`; the stored row's `dup_count` is bumped instead), then enforces the minimum
interval from the first matching `sample_rules` entry or `default_min_interval_ms`. UI-origin
messages are always stored. This keeps the history useful under chatty publishers without
touching what the live view sees.

**Live view.** `GET /api/stream?topics=…` registers a `Bus` subscriber with the client's filters
and a `SizedQueue` of `sse_queue_size`. `SseStream` (`routes/stream.rb`) pops events and writes
them straight to the socket; nothing is buffered server-side. Overflow drops the oldest event and
injects a `dropped` event; `: ping` heartbeats go out every `sse_heartbeat_s`; a stream with no
events for `sse_idle_timeout_s` is closed; `sse_max_clients` caps the number of streams (a further
client gets 503). Unsubscribe is idempotent and runs both from the stream's `ensure` and the close
callback, so a vanished client never leaks a slot.

**History, diff, chart, search.** All read paths go through `Store`: `history` pages by `before_id`
newest first; `previous` finds the stored row before a given id so `Differ.diff` can compare two
consecutive payloads; `series` extracts a numeric JSON path across a time range and bucket-averages
it to `max_points`; `search` runs an FTS5 `MATCH` with snippets and, when the topic filter has
wildcards, filters the candidate rows in Ruby up to `search_max_rows`.

**Presence.** `Presence.devices` walks the TopicRegistry for topics matching each rule, takes the
device id from `id_segment`, reads `online_path` from the last payload and compares `last_seen_ms`
with `stale_s`. Timelines are rebuilt from stored history on request (`timeline_max_rows`), so a
device's past needs its status topic to be stored, which the default sampling does.

**Publish.** `POST /api/publish` is refused when `publish_enabled` is off (403) or the broker is
down (503); QoS 2 is refused because the client library has no QoS 2 handshake. Before sending,
Ingest remembers a digest of the message for `publish_echo_ttl_s`; when the broker echoes it back,
the stored row and the `message` event carry `origin: ui`.

**Retention.** The Pruner wakes every `prune_interval_s`: delete rows older than `retention_days`,
then while `Store.db_size_bytes > max_db_bytes` delete the oldest `prune_batch` rows and run
`PRAGMA incremental_vacuum`, then drop stale empty `topics` rows. `Pruner.run_now` is
mutex-coalesced so an API-triggered run and the timer never overlap. `GET /api/stats` reports which
limit is governing.

**Settings.** `Setting.fetch` reads the table at use time, so every tunable applies on the next
message or request. `POST /api/settings` validates each key (JSON rules, integers, MQTT filters,
the masked password placeholder) and calls `Ingest.reconnect!` when a connection key changed.

## Configuration surface

Bootstrap: `MQTT_HOST/PORT/USER/PASS/CLIENT_ID` (seed the settings table on first boot only),
`DATABASE_PATH`, `PORT`, `RACK_ENV`, `LOG_LEVEL`. Runtime: the ~40 keys in the `settings` table,
edited on the Settings page or via the API. The complete table with defaults is in
[`configuration.md`](configuration.md). There are no constants in the code that a deployment would
need to change.

## Decisions and rationale

1. **One process, one broker connection.** A broker sees one client; the registry, bus and
   sampling state are consistent because there is exactly one of each. Horizontal scaling is not a
   goal for a broker explorer; vertical headroom comes from threads and bounded queues.
2. **SQLite + FTS5 instead of a time-series database.** Zero operational footprint, a single file to
   back up or discard, and full-text search over payloads comes for free. WAL mode keeps reads
   from blocking the writer; incremental vacuum lets the size cap actually shrink the file.
3. **Store less than you see.** Dedup and per-topic minimum intervals keep history meaningful under
   chatty publishers while the live view stays complete. Both are settings, not code.
4. **Two retention limits, size always wins.** Age gives predictable history; the byte cap
   guarantees the disk never fills regardless of traffic. `governing` in stats tells you which one
   is biting.
5. **Everything bounded.** Topic registry (LRU), SSE clients and queues, ingest backlog, query row
   scans, payload size, diff size. Each bound is a setting with a sane default.
6. **Settings in the database, read at use time.** No restart to retune, no cache to invalidate,
   and the Settings page is the only configuration UI needed. Environment variables only seed the
   first boot.
7. **Payloads are bytes.** Stored as BLOBs, interpreted as UTF-8/JSON only when displayed or
   diffed, so binary topics never break ingest or search.
8. **No authentication in the app.** Auth belongs to the reverse proxy in front of it; the app
   stays small and composes with whatever identity layer you already run. See
   [`security.md`](security.md).
9. **Additive migrations run on every boot.** Upgrades are `docker compose pull && up`; there is no
   separate migrate step and no destructive schema change.

## Current scope and non-goals

Today mqttscope observes one broker per instance, stores history locally, and offers no
multi-user model or built-in authentication. It does not act as a broker, a bridge or a rules
engine, and it does not retain data beyond the configured window. Those are the present boundaries,
chosen to keep the tool small and dependable; the architecture does not preclude extending them.

## Operations

- **Logs** go to stdout with a severity and a subsystem prefix (`[mqtt]`, `[db]`, `[store]`, `[sse]`,
  `[http]`, `[prune]`, `[presence]`, `[settings]`, `[thread]`); `LOG_LEVEL` sets the threshold. Background thread errors are logged with
  a full backtrace via `WorkerPool.safe_thread`.
- **Health.** The image's `HEALTHCHECK` curls `GET /api/stats` every 30 s, so `docker ps` shows
  `healthy` once Puma answers. The endpoint returns `ingest.connected` and database figures; `bin/verify`
  (`docker compose exec mqttscope /app/bin/verify`) checks the API, the broker connection, a live
  SSE event and the UI, exiting non-zero on failure. `connection` SSE events announce broker state
  changes to live clients.
- **Upgrade.** Pull the new image and recreate the container; migrations run at boot. Settings and
  history live in the `data/` volume and survive the upgrade. The footer shows the running
  `VERSION`; releases are tagged `vX.Y.Z` and listed in `CHANGELOG.md`.
- **Capacity.** Watch `db.size_bytes` vs `db.max_bytes` and `db.governing` in `/api/stats`; raise
  `max_db_bytes` or add `sample_rules` for noisy topic families when size governs. Keep
  `sse_max_clients` below Puma's max threads (16), since each stream holds one.
- **Recovery.** The database is observational and refills from the broker; if it is corrupted,
  stop the container, remove `data/mqttscope.db*` and start again, then re-enter the broker
  settings (or set the `MQTT_*` variables, which seed a fresh database).
