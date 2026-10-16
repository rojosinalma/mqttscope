# Contributing

Thanks for taking the time. Issues and pull requests are welcome; small, focused changes are the
easiest to review.

## Running it locally

```sh
git clone https://github.com/rojosinalma/mqttscope.git
cd mqttscope
bundle install
cp .env.example .env && $EDITOR .env          # point MQTT_HOST at a broker you can subscribe to
RACK_ENV=development bundle exec puma -C config/puma.rb config.ru
```

Or with Docker: `cp compose.example.yaml compose.yaml`, switch `image:` to `build: .`, add a
`compose.override.yaml` with `RACK_ENV=development` and a `.:/app` mount (see
[`docs/development.md`](docs/development.md)), then `docker compose up --build`. Code under `lib/`,
`models/`, `routes/` and `views/` reloads on the next request; `lib/ingest.rb`, `lib/bus.rb` and
`lib/pruner.rb` need a restart.

## Tests

```sh
bin/test                                       # all of test/*_test.rb
bundle exec ruby -Itest test/store_test.rb     # one file
```

Tests are Minitest and run against a throwaway SQLite file; no broker is needed. Add a test for any
behaviour change in `lib/` or `routes/api.rb`, in the file named after the module. `bin/verify`
smoke-tests a running instance (API, broker connection, a live SSE event, the UI) and is what I run
after a deploy.

## Code style and layout

- Ruby 3.3, Roda + Sequel + SQLite, Puma. `# frozen_string_literal: true` at the top of every file.
- Routes orchestrate (validate → call a module → return JSON); business logic lives in `lib/`,
  schema and models in `models/` and `db/migrations/`.
- Every action endpoint returns `{ok, message, ...data}` via `json_ok` / `json_err`; errors carry a
  reason.
- No tunable constants: anything a deployment might change is a `Setting` with a default, read at
  use time, and documented in `docs/configuration.md`.
- Every in-memory collection has a cap, every thread goes through `WorkerPool.safe_thread`, every
  stream has an idle timeout.
- Migrations are additive and run on every boot; never edit a shipped migration.
- When you change a module's public methods, update `docs/contracts.md` in the same change.

## Commits and PRs

- One logical change per commit, imperative subject line ("Add series bucketing", "Fix SSE leak on
  client close"), body only when the why is not obvious.
- Every commit is GPG- or SSH-signed (`git config commit.gpgsign true`); `main` is protected and
  only accepts signed, test-passing history.
- Run `bin/test` before pushing; the `run-tests` workflow runs it on every push and pull request.
- A PR describes what changed and how you verified it. Add a line to `CHANGELOG.md` under
  *Unreleased* for anything user-visible.

## Documentation

The README stays short (what it is, requirements, installation, usage, development, licence).
Everything else lives in `docs/` or in the standard files at the root:

| File | What goes there |
|---|---|
| `SECURITY.md` | how to report a vulnerability, supported versions |
| `CODE_OF_CONDUCT.md` | Contributor Covenant 2.1 |
| `docs/configuration.md` | environment variables, every settings key, sampling and presence rules, retention |
| `docs/api.md` | HTTP endpoints, response shapes, the SSE event types |
| `docs/contracts.md` | the Ruby interface of each module in `lib/` |
| `docs/SDD.md` | design: architecture, data model, flows, decisions, operations |
| `docs/security.md` | what the app does and does not protect, and how to deploy it safely |
| `docs/development.md` | running from a clone, tests, smoke test, migrations, repo layout |
| `CHANGELOG.md` | Keep a Changelog, one entry per user-visible change |

## Releasing

1. Update `VERSION` and move the *Unreleased* entries in `CHANGELOG.md` under the new version.
2. Commit, create a signed tag `vX.Y.Z` (`git tag -s`) and push it, then publish a GitHub release
   whose notes are that changelog section.
3. The `publish-image` workflow builds `ghcr.io/rojosinalma/mqttscope:X.Y.Z`, `:X.Y`, `:sha-<short>`
   and, from `main`, `:latest` (linux/amd64 and linux/arm64).

By contributing you agree that your contributions are licensed under the AGPL-3.0, like the rest of
the project (see [`LICENSE`](LICENSE)).
