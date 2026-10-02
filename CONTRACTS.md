# mqttscope — module and API contracts

Every module below is owned by one file. Callers rely on these signatures; change them here first.
Timestamps are Integer **milliseconds since epoch** (`ts_ms`). Payloads are `String` (binary-safe).

## Settings (`models/setting.rb`, `Setting.fetch(key, default)`)

| key | default | meaning |
|---|---|---|
| `mqtt_host` | `mosquitto` | broker host |
| `mqtt_port` | `1883` | |
| `mqtt_user` | `mqttscope` | |
| `mqtt_pass` | `ENV["MQTT_PASS"]` at first boot | |
| `mqtt_client_id` | `mqttscope` | |
| `mqtt_subscriptions` | `#,$SYS/#` | comma list of filters the ingest subscribes to |
| `mqtt_keepalive_s` | `30` | |
| `reconnect_backoff_s` | `2,5,10,30,60` | comma list |
| `publish_enabled` | `true` | UI publish allowed |
| `max_payload_bytes` | `262144` | larger payloads are stored truncated, flagged `truncated: true` |
| `dedup_enabled` | `true` | drop consecutive identical payloads per topic (bump `dup_count`) |
| `default_min_interval_ms` | `1000` | store at most one message per topic per interval |
| `sample_rules` | JSON `[{"pattern":"esp32/+/data","min_interval_ms":10000},{"pattern":"$SYS/#","min_interval_ms":60000}]` | first matching rule wins |
| `retention_days` | `7` | |
| `max_db_bytes` | `10737418240` | 10 GB, always enforced |
| `prune_interval_s` | `3600` | |
| `prune_batch` | `5000` | rows per delete batch |
| `max_topics` | `20000` | in-memory registry cap (LRU evict) |
| `rate_window_s` | `60` | window for msgs/s |
| `sse_max_clients` | `12` | must stay below Puma max threads (16) — each stream holds one |
| `sse_idle_timeout_s` | `300` | close a stream idle this long (no events, heartbeats don't count) |
| `sse_heartbeat_s` | `15` | `: ping` comment interval |
| `sse_queue_size` | `500` | per-client queue; overflow drops oldest and emits `{type:"dropped",n}` |
| `presence_rules` | JSON `[{"name":"esp32","pattern":"esp32/+/status","id_segment":1,"online_path":"online","label_path":"hostname","stale_s":90}]` | |
| `history_default_limit` | `200` | |
| `search_default_limit` | `100` | |
| `series_max_rows` | `50000` | rows scanned per `Store.series` call |
| `search_max_rows` | `20000` | rows scanned when a wildcard topic filter is applied in Ruby |
| `api_max_limit` | `5000` | cap on `limit` / `max_points` query params |
| `series_default_points` | `500` | default `max_points` |
| `timeline_max_rows` | `5000` | history rows read per device timeline |
| `diff_max_lines` | `2000` | longest text section line-diffed; larger → summary only |
| `ingest_max_backlog` | `10000` | if the MQTT client's read queue exceeds this, queued messages are acked and dropped (warned) |
| `publish_echo_ttl_s` | `10` | how long a UI publish is remembered to tag its echo `origin: ui` |

Settings are read at use time (no caching beyond a request), so edits apply immediately except
connection params (`Ingest.reconnect!` after saving those).

## Shared (written in the skeleton, do not replace)

```ruby
TopicMatch.match?(filter, topic)        # MQTT wildcards (+, #), "$SYS" topics only match filters starting with "$SYS"
TopicMatch.match_any?(filters, topic)
TopicMatch.valid_filter?(filter)        # for validating user input
WorkerPool.safe_thread(name) { ... }    # logs with backtrace, never raises
WorkerPool.log_error(name, error)

Bus.subscribe(filters: ["#"], max_queue: Setting.fetch(...)) -> Bus::Subscriber | nil (nil when sse_max_clients reached)
Bus.unsubscribe(sub)
Bus.publish(event)                      # Hash with :type; fan out to subscribers whose filters match event[:topic] (events without :topic go to everyone)
Bus.client_count
sub.queue                               # SizedQueue; pop with timeout for heartbeats
sub.filters
```

Bus events (Hashes, symbol keys, JSON-encoded as-is by the SSE route):

```
{type: "message", topic:, payload:, ts_ms:, retained: bool, qos:, size:, origin: "broker"|"ui", stored: bool, id: Integer|nil, truncated: bool}
{type: "topic",   topic:, first_seen_ms:}                       # a never-seen topic appeared
{type: "connection", connected: bool, error: String|nil, ts_ms:}
{type: "stats", ingest: {...Ingest.status}, ts_ms:}             # emitted by Ingest every rate_window_s/6 (≈10 s)
{type: "dropped", n: Integer}                                   # injected by the SSE route on queue overflow
```

`payload` in `message` events is the UTF-8 string if valid, else `nil` with `binary: true` and
`payload_b64:`.

## Ingest (`lib/ingest.rb`, owner A) — loaded once

```ruby
Ingest.start                       # idempotent; supervised thread, backoff reconnect, resubscribes
Ingest.reconnect!                  # drop the connection; the loop reconnects with current settings
Ingest.status                      # {connected:, since_ms:, error:, host:, port:, msgs_total:, msgs_per_s:, bytes_per_s:, topics: TopicRegistry.size, last_message_ms:}
Ingest.publish(topic:, payload:, retain: false, qos: 0)  # raises Ingest::NotConnected / ArgumentError; marks the echo origin "ui"
```

Per received packet, in order: `TopicRegistry.touch(...)` → `Sampling.store?(...)` → if true
`Store.record(...)` → `Bus.publish(message event)` (always, stored or not; `stored:` says which).
Received `$SYS/#` goes through the same path (sampling rule caps it). Emits `topic` events for
first-seen topics and `connection` events on state change. Subscriptions are QoS 1; QoS 2 publish is
refused (ruby-mqtt has no QoS 2 handshake). UI-origin messages are always stored. On a dedup hit
(`Sampling.last_reason(topic) == :dup`) `Store.bump_dup` is called instead of `record`.

## TopicRegistry (`lib/topic_registry.rb`, owner A) — reloadable

```ruby
TopicRegistry.touch(topic:, ts_ms:, size:, retained:, payload:)   # counts, rate ring, last payload (capped to max_payload_bytes), LRU
TopicRegistry.all        # Array of {topic:, count:, rate:, bytes_rate:, first_seen_ms:, last_seen_ms:, retained:, last_size:, last_payload:}
TopicRegistry.get(topic) # one entry or nil
TopicRegistry.size
TopicRegistry.warm(rows) # seed from Store.topics at boot
```

`retained:` is "the last message seen on this topic carried the retain flag" — on (re)connect the
broker replays retained messages with the flag set, so this is accurate right after subscribe.

## Sampling (`lib/sampling.rb`, owner B) — reloadable

```ruby
Sampling.store?(topic:, payload:, ts_ms:)   # applies dedup then min-interval; keeps per-topic last-stored state (bounded by max_topics)
Sampling.rule_for(topic)                    # {pattern:, min_interval_ms:} or default
Sampling.rules                              # parsed sample_rules, validated; bad JSON → [] with a warning
```

## Store (`lib/store.rb`, owner B) — reloadable

```ruby
Store.record(topic:, payload:, ts_ms:, retained:, qos:, origin:)  # -> {id:, truncated:} ; upserts topics row
Store.bump_dup(topic:, ts_ms:)                                    # dedup hit: dup_count+1, last_seen on the latest row
Store.topics                                                      # rows from topics table (for warm + merge)
Store.history(topic:, from_ms: nil, to_ms: nil, limit:, before_id: nil)   # newest first, Array of message hashes
Store.message(id)                                                 # one row or nil
Store.previous(topic:, before_id:)                                # the stored message just before id, or nil
Store.search(q:, topic_filter: nil, from_ms: nil, to_ms: nil, limit:)     # FTS5 on payload (+ LIKE fallback if FTS5 unavailable); Array of {id:, topic:, ts_ms:, snippet:, size:}
Store.series(topic:, path:, from_ms:, to_ms:, max_points:)        # numeric JSON path (dotted, e.g. "bands.low") → [[ts_ms, value], ...], bucket-averaged to max_points
Store.sys_latest                                                  # {"$SYS/broker/uptime" => payload, ...} latest stored per $SYS topic
Store.db_size_bytes                                               # main file + WAL
Store.stats                                                       # {messages:, topics:, oldest_ms:, newest_ms:, size_bytes:, max_bytes:, retention_days:, governing: "retention"|"size"|"none"}
```

Message hash: `{id:, topic:, ts_ms:, payload:, size:, retained:, qos:, origin:, dup_count:, truncated:}`.

## Pruner (`lib/pruner.rb`, owner B) — loaded once

```ruby
Pruner.start          # idempotent; sleeps prune_interval_s between runs
Pruner.run_now        # -> {deleted_by_age:, deleted_by_size:, size_before:, size_after:, duration_s:}; mutex-coalesced
Pruner.last_run       # the last result + :at_ms, or nil
```

Age rule first, then while `db_size_bytes > max_db_bytes` delete the oldest `prune_batch` rows;
`PRAGMA incremental_vacuum` after each batch. Also drops `topics` rows with no messages and not
seen for `retention_days`.

## Differ (`lib/differ.rb`, owner C) — reloadable, pure

```ruby
Differ.classify(payload)     # :json | :text | :binary | :empty
Differ.diff(old_payload, new_payload)
# -> {kind: "json"|"text"|"binary"|"same", summary: "2 changed, 1 added", changes: [...]}
# json change:  {path: "bands.low", op: "changed"|"added"|"removed", from: <json value>, to: <json value>}
# text change:  {line: Integer, op: "changed"|"added"|"removed", from: String, to: String}
Differ.flatten(json)         # {"a.b" => 1, "arr[0]" => "x"} dotted/indexed paths, used by series path pickers
Differ.numeric_paths(payload) # paths whose value is numeric, for the chart dropdown
```

## Presence (`lib/presence.rb`, owner C) — reloadable

```ruby
Presence.rules                       # parsed presence_rules
Presence.devices                     # from TopicRegistry: [{id:, name: rule name, label:, online: bool, topic:, last_seen_ms:, since_ms:, stale: bool, fields: {flattened last payload}}]
Presence.timeline(id:, from_ms:, to_ms:) # from Store.history: [{from_ms:, to_ms: nil|Integer, online: bool}] newest last
```

`online` = `online_path` truthy in the last payload **and** `now - last_seen_ms <= stale_s*1000`.
An LWT payload `{"online":false}` sets offline. `id` = topic segment `id_segment`. Non-JSON payloads
use the whole payload as the flag (`true 1 online on yes up connected` → online). `stale` = payload says
online but silent longer than `stale_s`. Timelines treat silence longer than `stale_s` as offline.
A bare JSON scalar flattens to path `""` (root) — `Store.series` must accept `path: ""`.

## HTTP API (`routes/api.rb`, owner D). All responses `{ok:, message:, ...}`; errors `json_err` with 4xx/5xx.

```
GET  /api/topics                                  -> {topics: [registry entries merged with Store.topics stored counts]}
GET  /api/messages?topic=&from_ms=&to_ms=&limit=&before_id=   -> {messages: [...]}   (topic required, exact)
GET  /api/messages/:id                            -> {message:}
GET  /api/diff?id=                                -> {diff:, from: message|nil, to: message}   (vs Store.previous)
GET  /api/series?topic=&path=&from_ms=&to_ms=&max_points=    -> {points: [[ts_ms, v], ...]}   (path optional; "" or "." = the payload itself)
GET  /api/paths?topic=                            -> {paths: Differ.numeric_paths(last payload)}
GET  /api/search?q=&topic=&from_ms=&to_ms=&limit= -> {results: [...]}
GET  /api/stats                                   -> {ingest:, db:, sys: Store.sys_latest, sse_clients:, prune: Pruner.last_run}
GET  /api/stats/series?topic=$SYS/...&from_ms=&to_ms=&max_points=   -> {points:}  (alias of /api/series)
GET  /api/devices                                 -> {devices:}
GET  /api/devices/:id/timeline?from_ms=&to_ms=    -> {timeline:}
POST /api/publish {topic, payload, retain?, qos?} -> json_ok("Published")  | 403 when publish_enabled=false | 503 when not connected
GET  /api/settings                                -> {settings: {key => value}}  (mqtt_pass masked as "••••" unless empty)
POST /api/settings {key: value, ...}              -> json_ok; validates JSON rule keys, ints, filters; unchanged "••••" leaves mqtt_pass alone; triggers Ingest.reconnect! if connection keys changed
POST /api/prune                                   -> json_ok with Pruner.run_now result
POST /api/reconnect                               -> json_ok
GET  /api/stream?topics=<comma filters, default "#">   SSE; event: <type>, data: <json>. Heartbeat comments, idle timeout, bounded by Bus.
```

## Pages (`routes/pages.rb` + `views/`, owner E)

`/` explorer · `/stats` · `/devices` · `/settings`. Layout: `views/layout.erb` (navbar, footer with VERSION, toast container, theme toggle). JS in `public/js/`, CSS in `public/css/app.css`.
