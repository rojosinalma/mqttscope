# HTTP API

Everything the UI shows is served under `/api/*`. All responses are JSON of the form
`{ok: true|false, message: "...", ...data}`; errors use 4xx/5xx status codes with `ok: false` and a
reason in `message`. Timestamps are Integer **milliseconds since epoch** (`ts_ms`). Query params
`limit` and `max_points` are capped by the `api_max_limit` setting.

## Endpoints

| Method | Path | Returns |
|---|---|---|
| GET | `/api/topics` | `topics` — registry entries merged with stored counts |
| GET | `/api/messages?topic=&from_ms=&to_ms=&limit=&before_id=` | `messages`, newest first (`topic` required, exact) |
| GET | `/api/messages/:id` | `message` |
| GET | `/api/diff?id=` | `diff`, `from` (message or `null`), `to` — vs the previous stored message of the same topic |
| GET | `/api/series?topic=&path=&from_ms=&to_ms=&max_points=` | `points` `[[ts_ms, value], …]`, bucket-averaged to `max_points`; `path` optional, `""` or `.` = the payload itself |
| GET | `/api/paths?topic=` | `paths` — numeric JSON paths of the topic's last payload |
| GET | `/api/search?q=&topic=&from_ms=&to_ms=&limit=` | `results` — `{id, topic, ts_ms, snippet, size}` (FTS5; `topic` may be a wildcard filter) |
| GET | `/api/stats` | `ingest`, `db`, `sys` (latest `$SYS` payloads), `sse_clients`, `prune` (last run) |
| GET | `/api/stats/series?topic=$SYS/…&from_ms=&to_ms=&max_points=` | `points` (alias of `/api/series`) |
| GET | `/api/devices` | `devices` |
| GET | `/api/devices/:id/timeline?from_ms=&to_ms=` | `timeline` — `[{from_ms, to_ms, online}]` |
| POST | `/api/publish` `{topic, payload, retain?, qos?}` | `ok`; 403 when `publish_enabled` is off, 503 when the broker is not connected; QoS 0 or 1 |
| GET | `/api/settings` | `settings` — `{key: value}`, `mqtt_pass` masked as `••••` unless empty |
| POST | `/api/settings` `{key: value, …}` | `ok`; validates JSON rules, integers and filters; an unchanged `••••` leaves `mqtt_pass` alone; reconnects when connection keys changed |
| POST | `/api/prune` | `ok` plus the prune result (`deleted_by_age`, `deleted_by_size`, `size_before`, `size_after`, `duration_s`) |
| POST | `/api/reconnect` | `ok`; drops the broker connection, the ingest loop reconnects with current settings |
| GET | `/api/stream?topics=<comma filters>` | Server-Sent Events, see below (default filter `#`) |

## Shapes

Topic entry (`/api/topics`):

```
{topic, count, rate, bytes_rate, first_seen_ms, last_seen_ms, retained, last_size, last_payload, stored_count}
```

`retained` means the last message seen on this topic carried the retain flag; on (re)connect the
broker replays retained messages with the flag set, so it is accurate right after subscribe.

Message (`/api/messages`, `/api/messages/:id`, `/api/diff`):

```
{id, topic, ts_ms, payload, size, retained, qos, origin: "broker"|"ui", dup_count, truncated}
```

Diff (`/api/diff`):

```
{kind: "json"|"text"|"binary"|"same", summary: "2 changed, 1 added", changes: [...]}
json change:  {path: "bands.low", op: "changed"|"added"|"removed", from, to}
text change:  {line, op: "changed"|"added"|"removed", from, to}
```

Device (`/api/devices`):

```
{id, name, label, online, topic, last_seen_ms, since_ms, stale, fields: {flattened last payload}}
```

Stats (`/api/stats`):

```
ingest: {connected, since_ms, error, host, port, msgs_total, msgs_per_s, bytes_per_s, topics, last_message_ms}
db:     {messages, topics, oldest_ms, newest_ms, size_bytes, max_bytes, retention_days, governing: "retention"|"size"|"none"}
```

## Server-Sent Events

`GET /api/stream?topics=a/#,b/+/c` opens an SSE stream filtered by MQTT wildcards. Each event is
`event: <type>` followed by `data: <json>`:

| Type | Data | When |
|---|---|---|
| `message` | `{topic, payload, ts_ms, retained, qos, size, origin, stored, id, truncated}` | every received message, stored or not (`stored` says which); binary payloads come as `payload: null, binary: true, payload_b64` |
| `topic` | `{topic, first_seen_ms}` | a never-seen topic appeared |
| `connection` | `{connected, error, ts_ms}` | broker connection state changed |
| `stats` | `{ingest: {...}, ts_ms}` | about every 10 s |
| `dropped` | `{n}` | the client's queue overflowed and `n` events were discarded |

Comment lines (`: ping`) are sent every `sse_heartbeat_s` to keep the connection alive. A stream
with no events for `sse_idle_timeout_s` is closed, and at most `sse_max_clients` streams are open at
once; the next one gets a 503.
