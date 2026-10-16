# mqttscope

[![run-tests](https://github.com/rojosinalma/mqttscope/actions/workflows/run-tests.yml/badge.svg)](https://github.com/rojosinalma/mqttscope/actions/workflows/run-tests.yml)
[![publish-image](https://github.com/rojosinalma/mqttscope/actions/workflows/publish-image.yml/badge.svg)](https://github.com/rojosinalma/mqttscope/actions/workflows/publish-image.yml)
[![release](https://img.shields.io/github/v/release/rojosinalma/mqttscope)](https://github.com/rojosinalma/mqttscope/releases)
[![license](https://img.shields.io/github/license/rojosinalma/mqttscope)](LICENSE)

![mqttscope explorer](docs/screenshot.png)

A self-hosted web explorer for an MQTT broker: a live topic tree with counts, rates and the last
payload; a week of searchable message history (SQLite with FTS5); readable diffs between
consecutive payloads; charts of any numeric JSON field; device presence derived from status
topics; broker `$SYS` statistics; and publishing from the browser behind a toggle. Everything runs
in a single process over a single broker connection, every tunable is edited at runtime on the
Settings page, and everything the UI shows is also served as JSON and Server-Sent Events under
`/api/*`. Configuration, API, design and operations are documented in [`docs/`](docs/).

## Requirements

1. Docker 24+ with Compose v2 — or, to run it directly, Ruby 3.3+ and Bundler 2.4+.
2. An MQTT broker speaking MQTT 3.1.1 or 5.0, reachable from the container. The broker user needs
   permission to subscribe to `#` and `$SYS/#`; publish permission is only needed for the Publish
   feature.
3. A local disk for the SQLite database (mounted at `./data` in the compose file).

## Installation

Prebuilt images are published to `ghcr.io/rojosinalma/mqttscope` (`latest`, `sha-<commit>`,
`<version>`; linux/amd64 and linux/arm64).

```sh
mkdir mqttscope && cd mqttscope
curl -fsSLO https://raw.githubusercontent.com/rojosinalma/mqttscope/main/.env.example
curl -fsSL https://raw.githubusercontent.com/rojosinalma/mqttscope/main/compose.example.yaml -o compose.yaml
cp .env.example .env
$EDITOR .env                 # set MQTT_HOST, MQTT_PORT, MQTT_USER, MQTT_PASS
mkdir data                   # the SQLite volume; the container writes it as uid 1000
docker compose up -d
```

The container runs as uid 1000. If your user has another uid, either `chown 1000 data` or add
`user: "$(id -u):$(id -g)"` to the service in `compose.yaml`. The `MQTT_*` variables seed the settings on the first boot; after that, change them on the Settings
page (see [`docs/configuration.md`](docs/configuration.md)).

## Usage

Open http://localhost:9292 — the explorer fills with topics as soon as the broker delivers the
first message. The same data is available as JSON:

```sh
curl -s http://localhost:9292/api/stats     # broker connection, database size, $SYS figures
curl -s http://localhost:9292/api/topics    # the topic tree with counts, rates and last payloads
```

Every endpoint and SSE event type is listed in [`docs/api.md`](docs/api.md).

## Development

```sh
git clone https://github.com/rojosinalma/mqttscope.git
cd mqttscope
bundle install
cp .env.example .env && $EDITOR .env
RACK_ENV=development bundle exec puma -C config/puma.rb config.ru
bin/test                     # Minitest, no broker needed
```

Running from a clone with Docker, the smoke test and the repo layout are in
[`docs/development.md`](docs/development.md); how to contribute is in
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

AGPL-3.0 — see [`LICENSE`](LICENSE). Copyright (C) 2026 rojosinalma.
