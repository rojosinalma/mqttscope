# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/rojosinalma/mqttscope/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/rojosinalma/mqttscope/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/rojosinalma/mqttscope/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/rojosinalma/mqttscope/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rojosinalma/mqttscope/releases/tag/v0.1.0
