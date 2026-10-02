# frozen_string_literal: true

module Pruner
  DAY_MS = 86_400_000

  @run_lock = Mutex.new
  @start_lock = Mutex.new
  @thread = nil
  @last_run = nil

  class << self
    def start
      @start_lock.synchronize do
        return @thread if @thread&.alive?

        @thread = WorkerPool.safe_thread("pruner") do
          loop do
            begin
              run_now
            rescue StandardError => e
              WorkerPool.log_error("pruner", e)
            end
            sleep [Setting.fetch("prune_interval_s", 3600), 1].max
          end
        end
      end
    end

    def run_now
      return { skipped: true } unless @run_lock.try_lock

      begin
        result = prune
        @last_run = result.merge(at_ms: now_ms)
        $log.info "[prune] age=#{result[:deleted_by_age]} size=#{result[:deleted_by_size]} " \
                  "topics=#{result[:topics_dropped]} #{mb(result[:size_before])} → #{mb(result[:size_after])} " \
                  "in #{result[:duration_s]}s"
        result
      ensure
        @run_lock.unlock
      end
    end

    def last_run = @last_run

    private

    def prune
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      size_before = Store.db_size_bytes
      batch = [Setting.fetch("prune_batch", 5000), 1].max
      cutoff = now_ms - Setting.fetch("retention_days", 7) * DAY_MS
      max_bytes = Setting.fetch("max_db_bytes", 10_737_418_240)

      by_age = drain(batch) { DB[:messages].where { ts_ms < cutoff }.order(:ts_ms) }
      # Logical size, not file size: deletes grow the WAL until the checkpoint below.
      by_size = drain(batch, until_done: -> { Store.used_bytes <= max_bytes }) { DB[:messages].order(:id) }
      topics = drop_topics(cutoff)
      DB.run("PRAGMA wal_checkpoint(TRUNCATE)")

      { deleted_by_age: by_age, deleted_by_size: by_size, topics_dropped: topics, size_before: size_before,
        size_after: Store.db_size_bytes,
        duration_s: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3) }
    end

    def drain(batch, until_done: nil)
      total = 0
      loop do
        break if until_done&.call

        ids = yield.limit(batch).select_map(:id)
        break if ids.empty?

        total += delete_batch(ids)
        break if until_done.nil? && ids.size < batch
      end
      total
    end

    def delete_batch(ids)
      deleted = DB.transaction(mode: :immediate) do
        DB[:messages].where(id: ids).group_and_count(:topic_id).each do |row|
          DB[:topics].where(id: row[:topic_id]).update(stored_count: Sequel[:stored_count] - row[:count])
        end
        DB[:messages].where(id: ids).delete
      end
      # Each step of this pragma frees one page; DB.run would only take the first.
      DB.fetch("PRAGMA incremental_vacuum").each { nil }
      deleted
    end

    def drop_topics(cutoff)
      empty = DB[:messages].where(topic_id: Sequel[:topics][:id]).select(1)
      dropped = DB[:topics].where { last_seen_ms < cutoff }.exclude(empty.exists).delete
      Store.forget_topics! if dropped.positive?
      dropped
    end

    def now_ms = (Time.now.to_f * 1000).to_i

    def mb(bytes) = format("%.1f MB", bytes / 1_048_576.0)
  end
end
