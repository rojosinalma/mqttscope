Sequel.migration do
  up do
    create_table(:settings) do
      String :key, primary_key: true
      String :value, text: true
    end

    create_table(:topics) do
      primary_key :id
      String :name, text: true, null: false, unique: true
      Integer :first_seen_ms, null: false
      Integer :last_seen_ms, null: false
      Integer :stored_count, null: false, default: 0
      TrueClass :retained, null: false, default: false
      index :last_seen_ms
    end

    create_table(:messages) do
      primary_key :id
      foreign_key :topic_id, :topics, null: false, on_delete: :cascade
      Integer :ts_ms, null: false
      File :payload, null: false
      Integer :size, null: false
      TrueClass :retained, null: false, default: false
      Integer :qos, null: false, default: 0
      String :origin, null: false, default: "broker"
      Integer :dup_count, null: false, default: 1
      TrueClass :truncated, null: false, default: false
      index [:topic_id, :ts_ms]
      index :ts_ms
    end

    # External-content FTS5 index over payloads; triggers keep it in step with messages.
    run "CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(payload, content='messages', content_rowid='id', tokenize='unicode61')"
    run <<~SQL
      CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
        INSERT INTO messages_fts(rowid, payload) VALUES (new.id, new.payload);
      END
    SQL
    run <<~SQL
      CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, payload) VALUES ('delete', old.id, old.payload);
      END
    SQL
  end

  down do
    run "DROP TRIGGER IF EXISTS messages_ad"
    run "DROP TRIGGER IF EXISTS messages_ai"
    run "DROP TABLE IF EXISTS messages_fts"
    drop_table(:messages)
    drop_table(:topics)
    drop_table(:settings)
  end
end
