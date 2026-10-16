# Configuration

mqttscope has two layers of configuration: a handful of environment variables that bootstrap the
process, and a settings table in the database that holds everything else and is edited at runtime
on the **Settings** page (or with `POST /api/settings`). Changes to settings apply immediately;
nothing needs a restart.

## Environment variables

Read from `.env` (next to `config.ru`) or the process environment.

| Variable | Default | Meaning |
|---|---|---|
| `MQTT_HOST` | `mosquitto` | broker host — **first boot only** |
| `MQTT_PORT` | `1883` | broker port — **first boot only** |
| `MQTT_USER` | *(empty)* | broker user — **first boot only** |
| `MQTT_PASS` | *(empty)* | broker password — **first boot only** |
| `MQTT_CLIENT_ID` | `mqttscope` | MQTT client id — **first boot only** |
| `DATABASE_PATH` | `data/mqttscope.db` | SQLite file (keep it on local disk, not on a network share) |
| `PORT` | `9292` | HTTP port |
| `RACK_ENV` | `development` | `production` in the image; `development` enables code reloading |
| `LOG_LEVEL` | `info` | stdout log level |

The `MQTT_*` variables only **seed** the settings table on the very first boot. After that the
values in the database win: change them on the Settings page, and mqttscope reconnects with the
new values.

## Settings

Every key below lives in the `settings` table and is read at use time, so an edit applies on the
next message or request. Connection keys (`mqtt_*`, `reconnect_backoff_s`) trigger a reconnect when
saved through the API.

| Key | Default | Meaning |
|---|---|---|
| `mqtt_host` | `ENV["MQTT_HOST"]` at first boot, else `mosquitto` | broker host |
| `mqtt_port` | `ENV["MQTT_PORT"]` at first boot, else `1883` | broker port |
| `mqtt_user` | `ENV["MQTT_USER"]` at first boot, else empty (anonymous) | broker user |
| `mqtt_pass` | `ENV["MQTT_PASS"]` at first boot | broker password |
| `mqtt_client_id` | `ENV["MQTT_CLIENT_ID"]` at first boot, else `mqttscope` | client id |
| `mqtt_subscriptions` | `#,$SYS/#` | comma list of filters the ingest subscribes to |
| `mqtt_keepalive_s` | `30` | MQTT keepalive |
| `reconnect_backoff_s` | `2,5,10,30,60` | comma list of reconnect delays |
| `publish_enabled` | `true` | allow publishing from the UI and `POST /api/publish` |
| `max_payload_bytes` | `262144` | larger payloads are stored truncated and flagged `truncated: true` |
| `dedup_enabled` | `true` | drop consecutive identical payloads per topic (bump `dup_count` instead) |
| `default_min_interval_ms` | `1000` | store at most one message per topic per interval |
| `sample_rules` | `[{"pattern":"$SYS/#","min_interval_ms":60000}]` | per-filter storage intervals, see below |
| `retention_days` | `7` | delete stored messages older than this |
| `max_db_bytes` | `10737418240` | 10 GB; always enforced |
| `prune_interval_s` | `3600` | seconds between prune runs |
| `prune_batch` | `5000` | rows per delete batch |
| `max_topics` | `20000` | in-memory topic registry cap (LRU eviction) |
| `rate_window_s` | `60` | window for the msgs/s figures |
| `sse_max_clients` | `12` | concurrent SSE streams; keep it below Puma's max threads (16), each stream holds one |
| `sse_idle_timeout_s` | `300` | close a stream idle this long (heartbeats do not count) |
| `sse_heartbeat_s` | `15` | `: ping` comment interval |
| `sse_queue_size` | `500` | per-client queue; overflow drops the oldest events and emits `{type:"dropped",n}` |
| `presence_rules` | `[]` | device presence rules, see below |
| `history_default_limit` | `200` | default `limit` for `/api/messages` |
| `search_default_limit` | `100` | default `limit` for `/api/search` |
| `series_max_rows` | `50000` | rows scanned per `/api/series` call |
| `search_max_rows` | `20000` | rows scanned when a wildcard topic filter is applied to a search |
| `api_max_limit` | `5000` | cap on `limit` / `max_points` query params |
| `series_default_points` | `500` | default `max_points` |
| `timeline_max_rows` | `5000` | history rows read per device timeline |
| `diff_max_lines` | `2000` | longest text section that is line-diffed; larger payloads get a summary only |
| `ingest_max_backlog` | `10000` | if the MQTT read queue exceeds this, queued messages are acked and dropped (with a warning) |
| `publish_echo_ttl_s` | `10` | how long a UI publish is remembered so its echo is tagged `origin: ui` |

## Sampling rules

`sample_rules` is a JSON array; the first rule whose MQTT filter matches a topic sets how often that
topic is stored. Topics with no matching rule use `default_min_interval_ms` (1 s). Example with a
chatty sensor family throttled to one stored message every 10 s:

```json
[
  {"pattern": "sensors/+/data", "min_interval_ms": 10000},
  {"pattern": "$SYS/#", "min_interval_ms": 60000}
]
```

Put the more specific pattern first. Sampling only affects what is stored; the live view still
sees every message. Dedup runs before sampling: an identical consecutive payload never reaches the
interval check, it just increments `dup_count` on the last stored row.

## Presence rules

`presence_rules` (default `[]`) turns status topics into the **Devices** list. Each rule names a
topic pattern, which topic segment is the device id, the JSON path that says "online", an optional
label path and how many seconds without a message make a device stale:

```json
[
  {"name": "sensors", "pattern": "sensors/+/status", "id_segment": 1,
   "online_path": "online", "label_path": "hostname", "stale_s": 90}
]
```

A device is online when the online field is truthy in its last payload **and** it reported within
`stale_s`. A last-will payload such as `{"online": false}` marks it offline right away. Non-JSON
payloads are read as the flag itself (`true`, `1`, `online`, `on`, `yes`, `up`, `connected`).
Timelines treat silence longer than `stale_s` as offline.

## Retention

Messages are kept for **7 days or until the database reaches 10 GB, whichever comes first**
(`retention_days`, `max_db_bytes`). Each prune run first deletes everything older than the age
limit, then, if the file is still over the size cap, deletes the oldest messages in batches of
`prune_batch` until it fits, running `PRAGMA incremental_vacuum` after each batch. It also drops
`topics` rows with no stored messages that have not been seen for `retention_days`.

The size cap is always enforced, so under a heavy load history may be shorter than 7 days;
`GET /api/stats` reports which limit is currently governing (`db.governing`), and `POST /api/prune`
runs a prune immediately. The data is observational and refills from the live broker, so there is
no backup mechanism — if you want one, copy the SQLite file while the service is stopped.
