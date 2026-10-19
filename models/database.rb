# frozen_string_literal: true

require "fileutils"
require "sequel"

Sequel.default_timezone = :utc
Sequel.extension :migration

unless defined?(DB)
  db_path = ENV.fetch("DATABASE_PATH", File.expand_path("../data/mqttscope.db", __dir__))
  FileUtils.mkdir_p(File.dirname(db_path))
  # auto_vacuum must be set before the first table exists and before WAL is enabled; later
  # changes need a VACUUM (migration 002 covers databases created before this ordering).
  # busy_handler_timeout waits in Ruby, so a thread blocked on the write lock releases the GVL
  # (the C busy_timeout Sequel installs holds it, which stalls every other thread while it waits).
  DB = Sequel.connect("sqlite://#{db_path}", max_connections: 10, timeout: 5000,
                                             after_connect: proc { |conn|
                                               conn.busy_handler_timeout = 5000
                                               conn.execute("PRAGMA synchronous = NORMAL")
                                             })
  DB.run("PRAGMA auto_vacuum = INCREMENTAL")
  DB.run("PRAGMA journal_mode = WAL")
  Sequel::Migrator.run(DB, File.expand_path("../db/migrations", __dir__))
  DB_PATH = db_path.freeze
  $log.info "[db] #{db_path} ready"
end
