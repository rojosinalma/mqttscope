# Module contracts

Each module below lives in one file. Callers rely on these signatures; when changing one, update it here first. Settings keys are listed in [`configuration.md`](configuration.md) and the HTTP API in [`api.md`](api.md).
Timestamps are Integer **milliseconds since epoch** (`ts_ms`). Payloads are `String` (binary-safe).

## Shared helpers (`lib/topic_match.rb`, `lib/worker_pool.rb`, `lib/bus.rb`)

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

## Ingest (`lib/ingest.rb`) — loaded once

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

## TopicRegistry (`lib/topic_registry.rb`) — reloadable

```ruby
TopicRegistry.touch(topic:, ts_ms:, size:, retained:, payload:)   # counts, rate ring, last payload (capped to max_payload_bytes), LRU
TopicRegistry.all        # Array of {topic:, count:, rate:, bytes_rate:, first_seen_ms:, last_seen_ms:, retained:, last_size:, last_payload:}
TopicRegistry.get(topic) # one entry or nil
TopicRegistry.size
TopicRegistry.warm(rows) # seed from Store.topics at boot
```

`retained:` is "the last message seen on this topic carried the retain flag" — on (re)connect the
broker replays retained messages with the flag set, so this is accurate right after subscribe.

## Sampling (`lib/sampling.rb`) — reloadable

```ruby
Sampling.store?(topic:, payload:, ts_ms:)   # applies dedup then min-interval; keeps per-topic last-stored state (bounded by max_topics)
Sampling.rule_for(topic)                    # {pattern:, min_interval_ms:} or default
Sampling.rules                              # parsed sample_rules, validated; bad JSON → [] with a warning
```

## Store (`lib/store.rb`) — reloadable

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

## Pruner (`lib/pruner.rb`) — loaded once

```ruby
Pruner.start          # idempotent; sleeps prune_interval_s between runs
Pruner.run_now        # -> {deleted_by_age:, deleted_by_size:, size_before:, size_after:, duration_s:}; mutex-coalesced
Pruner.last_run       # the last result + :at_ms, or nil
```

Age rule first, then while `db_size_bytes > max_db_bytes` delete the oldest `prune_batch` rows;
`PRAGMA incremental_vacuum` after each batch. Also drops `topics` rows with no messages and not
seen for `retention_days`.

## Differ (`lib/differ.rb`) — reloadable, pure

```ruby
Differ.classify(payload)     # :json | :text | :binary | :empty
Differ.diff(old_payload, new_payload)
# -> {kind: "json"|"text"|"binary"|"same", summary: "2 changed, 1 added", changes: [...]}
# json change:  {path: "bands.low", op: "changed"|"added"|"removed", from: <json value>, to: <json value>}
# text change:  {line: Integer, op: "changed"|"added"|"removed", from: String, to: String}
Differ.flatten(json)         # {"a.b" => 1, "arr[0]" => "x"} dotted/indexed paths, used by series path pickers
Differ.numeric_paths(payload) # paths whose value is numeric, for the chart dropdown
```

## Presence (`lib/presence.rb`) — reloadable

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

## Pages (`routes/pages.rb` + `views/`)

`/` explorer · `/stats` · `/devices` · `/settings`. Layout: `views/layout.erb` (navbar, footer with VERSION, toast container, theme toggle). JS in `public/js/`, CSS in `public/css/app.css`.
