# Development

## Running from a clone

Without Docker:

```sh
bundle install
cp .env.example .env && $EDITOR .env     # MQTT_HOST etc.
RACK_ENV=development bundle exec puma -C config/puma.rb config.ru
```

With Docker, mount the project at `/app` and set `RACK_ENV=development` — add a
`compose.override.yaml` next to your `compose.yaml`:

```yaml
services:
  mqttscope:
    build: .
    environment:
      - RACK_ENV=development
    volumes:
      - .:/app
```

In development the code in `lib/`, `models/`, `routes/` and the views reloads on the next request
(`rack-unreloader`, see `config.ru`). The broker connection (`lib/ingest.rb`), the bus
(`lib/bus.rb`) and the pruner (`lib/pruner.rb`) hold state and load once, so a change there needs a
process restart; a `Gemfile` or `Dockerfile` change needs an image rebuild.

## Tests

```sh
bin/test                                          # every test/*_test.rb, each in its own process and database
bundle exec ruby -Itest test/differ_test.rb       # a single file
```

Tests are Minitest; each file gets a throwaway SQLite database via `DATABASE_PATH`, so they need
no broker and no network.

## Smoke test against a running instance

```sh
bin/verify                                        # BASE=http://host:9292 bin/verify for a remote one
docker compose exec mqttscope /app/bin/verify     # inside the container
```

`bin/verify` checks that `/api/stats` and `/api/topics` answer, that the broker is connected,
that a live SSE event arrives within 20 s and that the UI renders. It exits non-zero on any
failure, which makes it usable as a container health check.

## Database migrations

Migrations in `db/migrations/` are Sequel migrations, additive and run on every boot
(`models/database.rb`). Add a new numbered file for a schema change; never edit a shipped one.

## Layout

| Path | Contents |
|---|---|
| `app.rb`, `config.ru`, `config/puma.rb` | Roda app, rack entry point, Puma config |
| `lib/` | business logic: ingest, bus, sampling, store, pruner, differ, presence, topic registry |
| `models/` | Sequel models and the database connection |
| `routes/` | HTTP routes: `api.rb` (JSON + SSE), `pages.rb` (HTML), `stream.rb` (SSE pump) |
| `views/`, `public/` | ERB templates, JS and CSS |
| `db/migrations/` | schema |
| `test/` | Minitest files, one per module |
| `docs/` | this documentation; `contracts.md` lists the module interfaces |
