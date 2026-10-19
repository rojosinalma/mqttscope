# frozen_string_literal: true

# Reverses 003. With secure-delete every deleted row is scrubbed token by token from the FTS
# segments: measured 2026-10-19 at 0.25 s per 20 KB row (50 s for 200 rows, 0.03 s without), so a
# 5000-row prune batch held the write lock and the GVL for ~20 min, starving ingest and the health
# check. A plain delete appends a tombstone instead; the pruner reclaims the stale entries with
# bounded 'merge' steps after each run. Persistent; stored in messages_fts_config.
Sequel.migration do
  up do
    run "INSERT INTO messages_fts(messages_fts, rank) VALUES ('secure-delete', 0)"
  end

  down do
    run "INSERT INTO messages_fts(messages_fts, rank) VALUES ('secure-delete', 1)"
  end
end
