# frozen_string_literal: true

# STUB — owner B replaces this file. Contract: CONTRACTS.md → Store.
module Store
  class << self
    def record(topic:, payload:, ts_ms:, retained:, qos:, origin:) = { id: nil, truncated: false }

    def bump_dup(topic:, ts_ms:) = nil

    def topics = []

    def history(topic:, from_ms: nil, to_ms: nil, limit: 200, before_id: nil) = []

    def message(_id) = nil

    def previous(topic:, before_id:) = nil

    def search(q:, topic_filter: nil, from_ms: nil, to_ms: nil, limit: 100) = []

    def series(topic:, path:, from_ms:, to_ms:, max_points: 500) = []

    def sys_latest = {}

    def db_size_bytes
      base = DB_PATH
      [base, "#{base}-wal"].sum { |f| File.exist?(f) ? File.size(f) : 0 }
    end

    def stats
      { messages: 0, topics: 0, oldest_ms: nil, newest_ms: nil, size_bytes: db_size_bytes,
        max_bytes: Setting.fetch("max_db_bytes", 0), retention_days: Setting.fetch("retention_days", 7), governing: "none" }
    end
  end
end
