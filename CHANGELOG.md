# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/rojosinalma/mqttscope/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rojosinalma/mqttscope/releases/tag/v0.1.0
