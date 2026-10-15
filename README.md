# mqttscope

A self-hosted web explorer for an MQTT broker: live topic tree, a week of searchable history,
payload diffs, numeric charts, device presence and broker stats, from a single process with a
single broker connection.

<!-- TODO: screenshot -->
![mqttscope explorer](docs/screenshot.png)

## Features

1. **Explorer** — live topic tree with message counts and rates, filterable, pausable.
2. **History** — stored messages per topic with time ranges (7 days by default), paged.
3. **Diffs** — readable JSON-path or line diffs between consecutive payloads of a topic.
4. **Charts** — plot any numeric JSON field (or a numeric payload) of a topic over time.
5. **Search** — full-text search over stored payloads (SQLite FTS5), optionally scoped by topic filter.
6. **Devices** — online/offline presence and timelines derived from status topics via configurable rules.
7. **Stats** — broker `$SYS` metrics with history, plus ingest and database statistics.
8. **Publish** — send messages (retain, QoS 0/1) from the UI, behind a toggle and a confirm step.
9. **Settings** — every tunable value is edited at runtime in the browser; no restart needed.
10. **JSON API + SSE** — everything the UI shows is available under `/api/*`.

## Quick start

```sh
git clone https://github.com/rojosinalma/mqttscope.git
cd mqttscope
cp .env.example .env
cp compose.example.yaml compose.yaml
$EDITOR .env                 # set MQTT_HOST, MQTT_PORT, MQTT_USER, MQTT_PASS
docker compose up -d --build
```

Open http://localhost:9292.

The broker user needs permission to **subscribe to `#` and `$SYS/#`**, and to publish if you want
to use the Publish feature. The database is written to `./data/mqttscope.db`.

## Configuration

Environment variables (read from `.env` or the process environment):

| Variable | Default | Meaning |
|---|---|---|
| `MQTT_HOST` | `mosquitto` | broker host — **first boot only** |
| `MQTT_PORT` | `1883` | broker port — **first boot only** |
| `MQTT_USER` | *(empty)* | broker user — **first boot only** |
| `MQTT_PASS` | *(empty)* | broker password — **first boot only** |
| `MQTT_CLIENT_ID` | `mqttscope` | MQTT client id — **first boot only** |
| `DATABASE_PATH` | `data/mqttscope.db` | SQLite file (keep it on local disk, not NFS) |
| `PORT` | `9292` | HTTP port |
| `RACK_ENV` | — | `development` enables code reloading |
| `LOG_LEVEL` | `info` | stdout log level |

The `MQTT_*` variables only **seed** the settings table on the very first boot. After that the
values in the database win: change them on the **Settings** page (or `POST /api/settings`), and
mqttscope reconnects with the new values.

Everything else — subscriptions, retention, sampling, presence rules, SSE limits, query caps — is a
runtime setting stored in the database and edited on the Settings page. Changes apply immediately.
The full list of keys, defaults and meanings is the settings table in [`CONTRACTS.md`](CONTRACTS.md).

### Sampling rules

`sample_rules` is a JSON array; the first rule whose MQTT filter matches a topic sets how often
that topic is stored. Topics with no matching rule use `default_min_interval_ms` (1 s). The default
is `[{"pattern": "$SYS/#", "min_interval_ms": 60000}]`. Example with a chatty sensor family added:

```json
[
  {"pattern": "esp32/+/data", "min_interval_ms": 10000},
  {"pattern": "$SYS/#", "min_interval_ms": 60000}
]
```

Put the more specific pattern first. Sampling only affects what is stored; the live view still sees
every message.

### Presence rules

`presence_rules` (default `[]`) turns status topics into the **Devices** list. Each rule names a
topic pattern, which topic segment is the device id, the JSON path that says "online", an optional
label path and how many seconds without a message make a device stale. Example:

```json
[
  {"name": "esp32", "pattern": "esp32/+/status", "id_segment": 1,
   "online_path": "online", "label_path": "hostname", "stale_s": 90}
]
```

A device is online when the online field is truthy in its last payload **and** it reported within
`stale_s`. A last-will payload such as `{"online": false}` marks it offline right away. Non-JSON
payloads are read as the flag itself (`true`, `1`, `online`, `on`, `yes`, `up`, `connected`).

## How it works

1. One MQTT connection subscribes to `#` and `$SYS/#` (`mqtt_subscriptions`), reconnecting with backoff.
2. Every message updates an in-memory topic registry: counts, rates, last payload.
3. Sampling decides whether it is stored: identical consecutive payloads are dropped (a duplicate
   counter is bumped instead), then each topic is stored at most once per interval.
4. Stored messages go to SQLite (WAL) with an FTS5 full-text index on the payload.
5. Every message, stored or not, goes onto an internal bus.
6. Browsers subscribe over Server-Sent Events (`/api/stream`) with their own topic filters;
   each stream has a bounded queue, a heartbeat and an idle timeout.
7. History, diffs, charts, search and device timelines are read back from SQLite via `/api/*`.
8. A pruner runs hourly and enforces the retention limits below.

## Retention

Messages are kept for **7 days or until the database reaches 10 GB, whichever comes first**
(`retention_days`, `max_db_bytes`). Each prune run first deletes everything older than the age
limit, then, if the file is still over the size cap, deletes the oldest messages in batches until it
fits. The size cap is always enforced, so under a heavy load history may be shorter than 7 days;
`/api/stats` reports which limit is currently governing, and `POST /api/prune` runs a prune
immediately. There are no backups: the data is observational and refills from the live broker.

## API

All responses are JSON `{ok: true|false, message: "...", ...data}`; errors use 4xx/5xx. Timestamps
are milliseconds since epoch. Full shapes in [`CONTRACTS.md`](CONTRACTS.md).

| Method | Path | Returns |
|---|---|---|
| GET | `/api/topics` | `topics` — registry entries with stored counts |
| GET | `/api/messages?topic=&from_ms=&to_ms=&limit=&before_id=` | `messages`, newest first |
| GET | `/api/messages/:id` | `message` |
| GET | `/api/diff?id=` | `diff`, `from`, `to` — vs the previous stored message |
| GET | `/api/series?topic=&path=&from_ms=&to_ms=&max_points=` | `points` `[[ts_ms, value], …]` |
| GET | `/api/paths?topic=` | `paths` — numeric JSON paths of the last payload |
| GET | `/api/search?q=&topic=&from_ms=&to_ms=&limit=` | `results` with snippets |
| GET | `/api/stats` | `ingest`, `db`, `sys`, `sse_clients`, `prune` |
| GET | `/api/stats/series?topic=$SYS/…` | `points` (alias of `/api/series`) |
| GET | `/api/devices` | `devices` |
| GET | `/api/devices/:id/timeline?from_ms=&to_ms=` | `timeline` |
| POST | `/api/publish` `{topic, payload, retain?, qos?}` | 403 if `publish_enabled` is off, 503 if not connected |
| GET | `/api/settings` | `settings` (`mqtt_pass` masked) |
| POST | `/api/settings` `{key: value, …}` | validated; reconnects if connection keys changed |
| POST | `/api/prune` | prune result |
| POST | `/api/reconnect` | reconnects the broker client |
| GET | `/api/stream?topics=<comma filters>` | SSE stream (default filter `#`) |

The stream emits `event: <type>` with JSON `data`. Types: `message` (topic, payload, ts_ms,
retained, qos, origin, stored, …; binary payloads come as `payload_b64`), `topic` (a new topic
appeared), `connection` (broker state), `stats` (ingest stats, about every 10 s) and `dropped`
(the client's queue overflowed). Comment heartbeats keep it alive.

## Development

Mount the project at `/app` and set `RACK_ENV=development`: code in `lib/`, `models/`, `routes/`
and the views reloads on the next request. The broker connection, bus and pruner load once and need
a process restart; a `Gemfile` or `Dockerfile` change needs an image rebuild.

```sh
bin/test                                          # runs every test/*_test.rb
bundle exec ruby -Itest test/differ_test.rb       # a single file
bin/verify                                        # smoke test against a running instance (BASE=http://host:9292)
```

`bin/verify` checks the API, that the broker is connected, that a live SSE event arrives within
20 s and that the UI renders. Migrations in `db/migrations/` are additive and run on every boot.

## Built for a homelab, generic by config

mqttscope was originally written for one homelab's broker (mosquitto, LAN-only), and it has no
authentication of its own. Nothing in the code is tied to that setup: broker, subscriptions,
retention, sampling and presence are all configuration.

## Security notes

1. **No built-in auth.** Anyone who can reach the port can read every stored message and change
   settings. Keep it on a trusted network, or put it behind your own reverse proxy with auth.
2. **Publish** can be turned off with `publish_enabled`; UI publishes are tagged `origin: ui`.
3. **Payloads are untrusted**: escaped in the UI, parsed defensively, capped by `max_payload_bytes`.
4. **Broker credentials** are stored in plain text in the SQLite settings table; protect the
   `data/` directory. To rotate, change the password on the broker, then update `mqtt_pass` in
   Settings — mqttscope reconnects with it.

## License

MIT — see [`LICENSE`](LICENSE).
