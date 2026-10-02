# Without secure-delete an FTS5 delete appends a tombstone as large as the deleted row's
# tokens, so pruning by size frees nothing until segment merges catch up (measured 2026-10-02:
# deleting every message left the file at its full size). Persistent; stored in messages_fts_config.
Sequel.migration do
  up do
    run "INSERT INTO messages_fts(messages_fts, rank) VALUES ('secure-delete', 1)"
  end

  down do
    run "INSERT INTO messages_fts(messages_fts, rank) VALUES ('secure-delete', 0)"
  end
end
