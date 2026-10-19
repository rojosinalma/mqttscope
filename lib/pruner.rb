# frozen_string_literal: true

module Pruner
  DAY_MS = 86_400_000
  # Every SQLite statement holds the write lock and the Ruby GVL until it returns, so the pruner
  # works in short steps (small delete batches, a few vacuumed pages at a time, bounded FTS merges)
  # and sleeps between them: a thread that re-takes the GVL right after a long C call starves the
  # others (measured 2026-10-19: Thread.pass alone left /api/healthz at 2-5 s and lost MQTT pings).
  VACUUM_STEP_PAGES = 1024
  MERGE_STEP_PAGES = 256
  STEP_PAUSE_S = 0.02
  SIZE_ROUNDS = 3

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
                  "topics=#{result[:topics_dropped]} fts_merges=#{result[:fts_merges]} " \
                  "#{mb(result[:size_before])} → #{mb(result[:size_after])} in #{result[:duration_s]}s"
        result
      ensure
        @run_lock.unlock
      end
    end

    def last_run = @last_run

    def running? = @run_lock.locked?

    private

    def prune
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      size_before = Store.db_size_bytes
      batch = [Setting.fetch("prune_batch", 500), 1].max
      cutoff = now_ms - Setting.fetch("retention_days", 7) * DAY_MS
      max_bytes = Setting.fetch("max_db_bytes", 10_737_418_240)

      by_age = drain(batch) { DB[:messages].where { ts_ms < cutoff }.order(:ts_ms) }
      by_size = 0
      merges = 0
      if Store.used_bytes > max_bytes
        # Once over the cap, prune down to the target so the next run is not over it again right away.
        by_size, merges = shrink_to(max_bytes * Setting.fetch("prune_target_pct", 90) / 100, batch)
      else
        merges = merge_fts(Setting.fetch("prune_merge_pages", 10_000))
      end
      topics = drop_topics(cutoff)
      vacuum
      DB.run("PRAGMA wal_checkpoint(TRUNCATE)")

      { deleted_by_age: by_age, deleted_by_size: by_size, topics_dropped: topics, fts_merges: merges,
        size_before: size_before, size_after: Store.db_size_bytes,
        duration_s: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3) }
    end

    # Deleted rows free their content pages at once, but their FTS entries only after a merge, so
    # each round deletes a proportional slice of the oldest rows, then merges and vacuums before it
    # measures again. Logical size, not file size: deletes grow the WAL until the final checkpoint.
    def shrink_to(target, batch)
      deleted = 0
      merges = 0
      SIZE_ROUNDS.times do
        used = Store.used_bytes
        count = DB[:messages].count
        break if used <= target || count.zero?

        rows = ((used - target) * count.to_f / used).ceil
        deleted += drain(batch, max_rows: rows) { DB[:messages].order(:id) }
        merges += merge_fts(nil)
        vacuum
      end
      $log.warn "[prune] still over target after #{SIZE_ROUNDS} rounds: #{mb(Store.used_bytes)} > #{mb(target)}" if
        Store.used_bytes > target
      [deleted, merges]
    end

    def drain(batch, max_rows: nil)
      total = 0
      loop do
        size = max_rows ? [batch, max_rows - total].min : batch
        break if size <= 0

        ids = yield.limit(size).select_map(:id)
        break if ids.empty?

        total += delete_batch(ids)
        break if ids.size < size

        pause
      end
      total
    end

    def delete_batch(ids)
      DB.transaction(mode: :immediate) do
        DB[:messages].where(id: ids).group_and_count(:topic_id).each do |row|
          DB[:topics].where(id: row[:topic_id]).update(stored_count: Sequel[:stored_count] - row[:count])
        end
        DB[:messages].where(id: ids).delete
      end
    end

    # Frees the freelist a step at a time; a step that frees nothing means auto_vacuum is off.
    def vacuum
      left = freelist_count
      until left.zero?
        DB.fetch("PRAGMA incremental_vacuum(#{VACUUM_STEP_PAGES})").each { nil }
        now = freelist_count
        break if now >= left

        left = now
        pause
      end
    end

    def freelist_count = DB.fetch("PRAGMA freelist_count").single_value

    # FTS5 deletes only append tombstones; merging segments drops them and the dead entries. A
    # positive step continues a running merge or merges a level with enough segments; when there is
    # nothing eligible, one negative step starts a full optimize, and positive steps finish it (the
    # SQLite docs for the "merge" command). Stops after `pages` written (nil: when the optimize is
    # done) so continuous ingest cannot keep it merging forever. Returns the number of steps run.
    def merge_fts(pages)
      steps = 0
      param = MERGE_STEP_PAGES
      optimizing = false
      DB.synchronize do |conn|
        while pages.nil? || steps * MERGE_STEP_PAGES < pages
          before = conn.total_changes
          conn.execute("INSERT INTO messages_fts(messages_fts, rank) VALUES ('merge', ?)", [param])
          steps += 1
          if conn.total_changes - before >= 2
            param = MERGE_STEP_PAGES
          elsif optimizing
            break
          else
            optimizing = true
            param = -MERGE_STEP_PAGES
          end
          pause
        end
      end
      steps
    end

    def drop_topics(cutoff)
      empty = DB[:messages].where(topic_id: Sequel[:topics][:id]).select(1)
      dropped = DB[:topics].where { last_seen_ms < cutoff }.exclude(empty.exists).delete
      Store.forget_topics! if dropped.positive?
      dropped
    end

    def pause = sleep(STEP_PAUSE_S)

    def now_ms = (Time.now.to_f * 1000).to_i

    def mb(bytes) = format("%.1f MB", bytes / 1_048_576.0)
  end
end
