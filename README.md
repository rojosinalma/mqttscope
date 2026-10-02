# mqttscope

A web explorer for the homelab MQTT broker (`mosquitto`). It shows the live topic tree, keeps a
week of message history, renders readable diffs between consecutive payloads, charts numeric
fields, tracks device presence, graphs broker `$SYS` stats, searches payloads and can publish.
It replaces the stock `mqtt-explorer`.

Open it at [https://mqttscope.example.com](https://mqttscope.example.com) (LAN only, no login).

## How it works

1. One MQTT connection (user `mqttscope`) subscribes to `#` and `$SYS/#`, reconnecting with backoff.
2. Every message updates an in-memory topic registry: counts, rates, last payload.
3. Sampling decides whether it is stored: identical consecutive payloads are dropped (a duplicate
   counter is bumped instead), then each topic is stored at most once per interval.
4. Stored messages go to SQLite (WAL) with an FTS5 full-text index on the payload.
5. Every message, stored or not, goes onto an internal bus.
6. Browsers subscribe over Server-Sent Events (`/api/stream`) with their own topic filters;
   each stream has a bounded queue, a heartbeat and an idle timeout.
7. History, diffs, charts, search and device timelines are read back from SQLite via `/api/*`.
8. A pruner runs hourly and enforces the retention limits below.

## Running it

It is a container service built from this directory's `Dockerfile`, with the
project mounted at `/app`. Ruby code in `lib/`, `models/`, `routes/` and the views reloads on the
next request; the connection, bus and pruner code loads once and needs a container restart.

```
docker logs -f mqttscope            # logs
docker exec mqttscope /app/bin/verify   # smoke test: API, broker connected, live SSE event, UI
docker restart mqttscope            # pick up changes to once-loaded files
```

After a `Gemfile` or `Dockerfile` change, rebuild with `docker compose build` here and start the
service again through the orchestrator.

The database lives in `data/mqttscope.db`. There are no backups: the data is observational and
refills from the live broker.

## Settings

Everything tunable lives in the database and is edited on the **Settings** page; changes apply
immediately (connection settings trigger a reconnect). The full list of keys, defaults and their
meaning is the settings table in [`CONTRACTS.md`](CONTRACTS.md).

`.env` holds only `MQTT_PASS`, which seeds the broker password setting on the very first boot.
After that the value in Settings is the one used.

## Retention

Messages are kept for **7 days or until the database reaches 10 GB, whichever comes first**
(`retention_days`, `max_db_bytes`). Each prune run first deletes everything older than the age
limit, then, if the file is still over the size cap, deletes the oldest messages in batches until it
fits. The size cap is always enforced, so under a heavy load history may be shorter than 7 days;
`/api/stats` reports which limit is currently governing, and `POST /api/prune` runs a prune
immediately.

## Sampling rules

`sample_rules` is a JSON array; the first rule whose MQTT filter matches a topic sets how often
that topic is stored. Topics with no matching rule use `default_min_interval_ms` (1 s).

```json
[
  {"pattern": "esp32/+/data", "min_interval_ms": 10000},
  {"pattern": "$SYS/#", "min_interval_ms": 60000}
]
```

To add one, edit `sample_rules` in Settings and put the more specific pattern first. Sampling only
affects what is stored; the live view still sees every message.

## Presence rules

`presence_rules` turns status topics into the **Devices** list. Each rule names a topic pattern,
which topic segment is the device id, the JSON path that says "online", an optional label path and
how many seconds without a message make a device stale:

```json
[
  {"name": "esp32", "pattern": "esp32/+/status", "id_segment": 1,
   "online_path": "online", "label_path": "hostname", "stale_s": 90}
]
```

A device is online when the online field is truthy in its last payload **and** it reported within
`stale_s`. A last-will payload such as `{"online": false}` marks it offline right away. Add a rule
in Settings for any other family of devices that publishes a status topic.

## Rotating the broker password

```
docker exec mosquitto mosquitto_passwd -b /mosquitto/config/passwd mqttscope <new-password>
docker exec mosquitto kill -HUP 1
```

The HUP makes mosquitto reload its password file without a restart. Then enter the new password in
Settings → `mqtt_pass` and save; mqttscope reconnects with it. Note the broker has no ACL file, so
this user can read and write every topic.
