# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.2] - 2026-10-19

### Fixed

- The pruner froze the whole process for about 20 minutes per 5000-row batch once the database hit
  `max_db_bytes`: FTS5 `secure-delete` scrubbed every token of every deleted row (0.25 s per 20 KB row),
  and the sqlite3 gem holds the GVL while a statement runs, so ingest lost messages with `database is
  locked`, the MQTT keepalive lapsed and the health check timed out. Migration 004 turns `secure-delete`
  off; the pruner now works in short steps (500-row batches, 4 MB vacuum steps, 256-page FTS merge
  steps) and reclaims deleted index entries with bounded merges.
- Lock waits use `busy_handler_timeout`, which sleeps in Ruby and lets other threads run.
- `MS.fmtISO` and `MS.fmtNum` no longer throw under a browser locale that `Intl` rejects (such as
  `en-US@posix`); they fall back to `en-US`.

### Added

- `GET /api/healthz`, a cheap liveness probe; the container health check uses it instead of `/api/stats`.
- Settings `prune_target_pct` (prune down to this share of the cap once over it, default 90) and
  `prune_merge_pages` (FTS pages merged per run, default 10000). `prune_batch` defaults to 500.

## [0.3.1] - 2026-10-16

### Changed

- Icons come from tailor's Iconify sprite (`public/tailor/icons.svg`, 50 Bootstrap Icons subsetted by
  `tailor apply --icons`) as inline `<svg class="t-icon">` references; I removed the Bootstrap Icons font
  and its stylesheet from `public/vendor/`. A small `MS.icon(name)` helper builds them in the page scripts.
- `app.css` lost the stopgaps that tailor core 0.5.1 now covers: `t-nowrap`, the card header tools slot
  (`t-card-tools`), the narrow-viewport shell grid fix, the 1140px search dialog (`data-size="xl"`) and the
  `width: auto` toolbar selects/inputs (`data-width="auto"`).

## [0.3.0] - 2026-10-16

### Changed

- The UI runs on [tailor](https://github.com/rojosinalma/tailor): one markup vocabulary rendered by
  eight switchable skins (Bootstrap look by default) and 21 colour palettes (Dracula by default), with a
  light/dark toggle. Skin, palette and mode are picked in the navbar and remembered per browser. The
  vendored assets live under `public/tailor/` (managed by `tailor sync`); Bootstrap and `dracula.css`
  are gone, Bootstrap Icons are served locally instead of from a CDN.
- Modals, toasts and tabs are native `<dialog>` elements and tailor behaviour instead of Bootstrap JS.

## [0.2.1] - 2026-10-16

### Changed

- Licence changed from MIT to AGPL-3.0.
- The container runs as a non-root user (uid 1000) and carries a `HEALTHCHECK` against `/api/stats`.
  Upgrading: the mounted `data/` directory must be writable by uid 1000 (`chown -R 1000 data`, or set
  `user:` in your compose file to the uid that owns it).
- README restructured (badges, requirements with minimum versions, installation, usage, development).

### Added

- `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue and pull request templates, Dependabot for Bundler,
  GitHub Actions and the base image.

## [0.2.0] - 2026-10-16

### Added

- GitHub Actions workflow publishing `ghcr.io/rojosinalma/mqttscope` (linux/amd64, linux/arm64) on every push to `main` and every `v*` tag.
- `compose.example.yaml` uses the published image; the Dockerfile defaults to `RACK_ENV=production`.
- `run-tests` workflow running `bin/test` on every push and pull request; OCI labels on the image.
- `CONTRIBUTING.md` and topic docs under `docs/` (configuration, API, contracts, design, security, development).

## [0.1.0] - 2026-10-16

### Added

- Live topic tree with message counts, rates and the last payload, streamed over Server-Sent Events.
- 7-day message history in SQLite with FTS5 full-text search on payloads.
- Diffs between consecutive payloads, with payload classification (JSON, text, binary, empty).
- Charts of numeric fields picked from a topic's JSON payloads.
- Device presence from configurable status-topic rules (`presence_rules`).
- Broker statistics from `$SYS` topics.
- Publishing from the UI behind the `publish_enabled` toggle, stored with `origin: ui` for audit.
- Runtime Settings page; broker credentials are seeded from the environment on first boot.
- Retention by age (`retention_days`) and database size (`max_db_bytes`).
- Docker Compose quick start.

[Unreleased]: https://github.com/rojosinalma/mqttscope/compare/v0.3.2...HEAD
[0.3.2]: https://github.com/rojosinalma/mqttscope/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/rojosinalma/mqttscope/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/rojosinalma/mqttscope/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/rojosinalma/mqttscope/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/rojosinalma/mqttscope/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rojosinalma/mqttscope/releases/tag/v0.1.0
