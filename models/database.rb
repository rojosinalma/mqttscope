# frozen_string_literal: true

require "fileutils"
require "sequel"

Sequel.default_timezone = :utc
Sequel.extension :migration

unless defined?(DB)
  db_path = ENV.fetch("DATABASE_PATH", File.expand_path("../data/mqttscope.db", __dir__))
  FileUtils.mkdir_p(File.dirname(db_path))
  DB = Sequel.connect("sqlite://#{db_path}", max_connections: 10, timeout: 5000)
  DB.run("PRAGMA journal_mode = WAL")
  DB.run("PRAGMA synchronous = NORMAL")
  DB.run("PRAGMA auto_vacuum = INCREMENTAL")
  Sequel::Migrator.run(DB, File.expand_path("../db/migrations", __dir__))
  DB_PATH = db_path.freeze
  $log.info "[db] #{db_path} ready"
end
