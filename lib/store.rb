# frozen_string_literal: true

require "json"

module Store
  SNIPPET_OPEN = "«"
  SNIPPET_CLOSE = "»"
  SNIPPET_ELLIPSIS = "…"
  SNIPPET_TOKENS = 16

  @mutex = Mutex.new
  @topic_ids = {}

  class << self
    def record(topic:, payload:, ts_ms:, retained:, qos:, origin:)
      bytes = payload.to_s.b
      max = Setting.fetch("max_payload_bytes", 262_144)
      truncated = bytes.bytesize > max
      stored = truncated ? bytes.byteslice(0, max) : bytes
      row = { ts_ms: ts_ms, payload: Sequel.blob(stored), size: bytes.bytesize, retained: retained ? true : false,
              qos: qos.to_i, origin: origin.to_s, truncated: truncated }

      id = with_topic_retry(topic) do
        DB.transaction(mode: :immediate) do
          topic_id = topic_id!(topic, ts_ms)
          message_id = DB[:messages].insert(row.merge(topic_id: topic_id))
          DB[:topics].where(id: topic_id).update(
            stored_count: Sequel[:stored_count] + 1, retained: row[:retained],
            last_seen_ms: Sequel.function(:max, :last_seen_ms, ts_ms)
          )
          message_id
        end
      end
      { id: id, truncated: truncated }
    end

    def bump_dup(topic:, ts_ms:)
      topic_id = topic_id(topic) or return

      DB.transaction(mode: :immediate) do
        latest = DB[:messages].where(topic_id: topic_id).reverse(:ts_ms, :id).limit(1).select(:id)
        DB[:messages].where(id: latest).update(dup_count: Sequel[:dup_count] + 1)
        DB[:topics].where(id: topic_id).update(last_seen_ms: Sequel.function(:max, :last_seen_ms, ts_ms))
      end
      nil
    end

    def topics = DB[:topics].order(:name).all

    def history(topic:, limit:, from_ms: nil, to_ms: nil, before_id: nil)
      topic_id = topic_id(topic) or return []

      ds = in_range(Message.where(topic_id: topic_id), from_ms, to_ms)
      ds = before(ds, before_id) if before_id
      ds.reverse(:ts_ms, :id).limit(limit).all.map { |m| m.to_api(topic_name: topic) }
    end

    def message(id)
      row = Message.where(Sequel[:messages][:id] => id).association_join(:topic)
                   .select_all(:messages).select_append(Sequel[:topic][:name].as(:topic_name)).first
      row&.to_api(topic_name: row[:topic_name])
    end

    def previous(topic:, before_id:)
      topic_id = topic_id(topic) or return

      before(Message.where(topic_id: topic_id), before_id).reverse(:ts_ms, :id).first&.to_api(topic_name: topic)
    end

    def search(q:, limit:, topic_filter: nil, from_ms: nil, to_ms: nil)
      terms = search_terms(q)
      return [] if terms.empty? || limit.to_i <= 0

      fts? ? fts_search(terms, topic_filter, from_ms, to_ms, limit) : like_search(terms, topic_filter, from_ms, to_ms, limit)
    rescue Sequel::DatabaseError => e
      $log.warn "[store] search #{q.inspect} failed: #{e.message}"
      []
    end

    def series(topic:, path:, from_ms:, to_ms:, max_points:)
      topic_id = topic_id(topic) or return []

      text = Sequel.cast(:payload, String)
      value = Sequel.case([[Sequel.function(:json_valid, text), Sequel.function(:json_extract, text, json_path(path))]], nil)
      ds = in_range(DB[:messages].where(topic_id: topic_id), from_ms, to_ms)
           .reverse(:ts_ms, :id).limit(Setting.fetch("series_max_rows", 50_000))
           .select(:ts_ms, value.as(:v))
      points = []
      ds.each { |r| points << [r[:ts_ms], r[:v]] if r[:v].is_a?(Numeric) }
      bucket(points.reverse!, max_points.to_i)
    rescue ArgumentError => e
      $log.warn "[store] series #{topic} #{path.inspect}: #{e.message}"
      []
    end

    def sys_latest
      latest = DB[:messages].where(topic_id: Sequel[:topics][:id]).reverse(:ts_ms, :id).limit(1).select(:id)
      DB[:topics].join(:messages, id: latest).where(Sequel.like(Sequel[:topics][:name], "$SYS/%"))
                 .select(Sequel[:topics][:name], Sequel[:messages][:payload])
                 .to_hash(:name, :payload).transform_values { |p| p.to_s.dup.force_encoding(Encoding::UTF_8).scrub }
    end

    def db_size_bytes = [DB_PATH, "#{DB_PATH}-wal"].sum { |f| File.exist?(f) ? File.size(f) : 0 }

    def used_bytes
      page_size, pages, free = %w[page_size page_count freelist_count].map { |p| DB.fetch("PRAGMA #{p}").single_value }
      (pages - free) * page_size
    end

    def stats
      size = db_size_bytes
      max_bytes = Setting.fetch("max_db_bytes", 10_737_418_240)
      days = Setting.fetch("retention_days", 7)
      range = DB[:messages].select { [min(:ts_ms).as(:oldest), max(:ts_ms).as(:newest)] }.first
      governing =
        if size >= max_bytes then "size"
        elsif range[:oldest] && range[:oldest] < now_ms - days * 86_400_000 then "retention"
        else "none"
        end
      { messages: DB[:messages].count, topics: DB[:topics].count, oldest_ms: range[:oldest], newest_ms: range[:newest],
        size_bytes: size, max_bytes: max_bytes, retention_days: days, governing: governing }
    end

    def forget_topics! = @mutex.synchronize { @topic_ids.clear }

    private

    def now_ms = (Time.now.to_f * 1000).to_i

    def topic_id(name)
      cached = @mutex.synchronize { @topic_ids[name] }
      return cached if cached

      id = DB[:topics].where(name: name).get(:id)
      cache_topic(name, id) if id
      id
    end

    def topic_id!(name, ts_ms)
      topic_id(name) || begin
        DB[:topics].insert_conflict(:ignore).insert(name: name, first_seen_ms: ts_ms, last_seen_ms: ts_ms)
        cache_topic(name, DB[:topics].where(name: name).get(:id))
      end
    end

    def cache_topic(name, id)
      max = [Setting.fetch("max_topics", 20_000), 1].max
      @mutex.synchronize do
        @topic_ids.delete(name)
        @topic_ids[name] = id
        @topic_ids.shift while @topic_ids.size > max
      end
      id
    end

    # The Pruner may drop a topics row whose id is still cached here.
    def with_topic_retry(name)
      yield
    rescue Sequel::ForeignKeyConstraintViolation
      @mutex.synchronize { @topic_ids.delete(name) }
      yield
    end

    def in_range(ds, from_ms, to_ms)
      ds = ds.where { ts_ms >= from_ms } if from_ms
      ds = ds.where { ts_ms <= to_ms } if to_ms
      ds
    end

    def before(ds, before_id)
      anchor = DB[:messages].where(id: before_id).get(:ts_ms)
      return ds.where { id < before_id } unless anchor

      ds.where(Sequel.lit("(ts_ms, id) < (?, ?)", anchor, before_id))
    end

    def search_terms(q)
      q.to_s.scan(/"[^"]*"\*?|\S+/).filter_map do |raw|
        prefix = raw.end_with?("*")
        text = raw.delete_suffix("*").delete_prefix('"').delete_suffix('"').delete('"').strip
        { text: text, prefix: prefix } unless text.empty?
      end
    end

    def fts? = DB.table_exists?(:messages_fts)

    def fts_search(terms, topic_filter, from_ms, to_ms, limit)
      match = terms.map { |t| %("#{t[:text]}"#{'*' if t[:prefix]}) }.join(" ")
      snippet = Sequel.function(:snippet, :messages_fts, 0, SNIPPET_OPEN, SNIPPET_CLOSE, SNIPPET_ELLIPSIS, SNIPPET_TOKENS)
      ds = DB[:messages_fts]
           .join(:messages, id: Sequel[:messages_fts][:rowid])
           .join(:topics, id: Sequel[:messages][:topic_id])
           .where(Sequel.lit("messages_fts MATCH ?", match))
           .select(Sequel[:messages][:id], Sequel[:topics][:name].as(:topic), Sequel[:messages][:ts_ms],
                   Sequel[:messages][:size], snippet.as(:snippet))
      collect(scoped(ds, topic_filter, from_ms, to_ms).reverse(Sequel[:messages_fts][:rowid]), topic_filter, limit) do |r|
        r.merge(snippet: utf8(r[:snippet]))
      end
    end

    def like_search(terms, topic_filter, from_ms, to_ms, limit)
      text = Sequel.cast(Sequel[:messages][:payload], String)
      ds = DB[:messages].join(:topics, id: Sequel[:messages][:topic_id])
                        .select(Sequel[:messages][:id], Sequel[:topics][:name].as(:topic), Sequel[:messages][:ts_ms],
                                Sequel[:messages][:size], Sequel[:messages][:payload])
      terms.each { |t| ds = ds.where(Sequel.like(text, "%#{escape_like(t[:text])}%", case_insensitive: true)) }
      collect(scoped(ds, topic_filter, from_ms, to_ms).reverse(Sequel[:messages][:id]), topic_filter, limit) do |r|
        payload = utf8(r.delete(:payload))
        r.merge(snippet: excerpt(payload, terms.first[:text]))
      end
    end

    def scoped(ds, topic_filter, from_ms, to_ms)
      ds = ds.where { Sequel[:messages][:ts_ms] >= from_ms } if from_ms
      ds = ds.where { Sequel[:messages][:ts_ms] <= to_ms } if to_ms
      return ds if topic_filter.nil? || topic_filter.empty?

      literal = topic_filter[/\A[^+#]*/]
      return ds.where(Sequel[:topics][:name] => topic_filter) if literal == topic_filter

      literal.empty? ? ds : ds.where(Sequel.like(Sequel[:topics][:name], "#{escape_like(literal)}%"))
    end

    # The LIKE prefix only narrows; the MQTT filter itself is applied here, scanning a bounded number of rows.
    def collect(ds, topic_filter, limit)
      wildcard = topic_filter && topic_filter.match?(/[+#]/)
      return ds.limit(limit).all.map { |r| yield r } unless wildcard

      results = []
      ds.limit(Setting.fetch("search_max_rows", 20_000)).each do |r|
        next unless TopicMatch.match?(topic_filter, r[:topic])

        results << yield(r)
        break if results.size >= limit
      end
      results
    end

    def excerpt(payload, term)
      at = payload.downcase.index(term.downcase) || 0
      from = [at - 60, 0].max
      out = payload[from, 160 + term.size].to_s
      "#{from.positive? ? SNIPPET_ELLIPSIS : ''}#{out}#{from + out.size < payload.size ? SNIPPET_ELLIPSIS : ''}"
    end

    def escape_like(text) = text.gsub(/[\\%_]/) { |c| "\\#{c}" }

    def utf8(value) = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub

    # "bands.low" / "arr[0].x" / "" → SQLite JSON path with quoted keys.
    def json_path(path)
      path.to_s.scan(/\[(\d+)\]|([^.\[\]]+)/).reduce(+"$") do |out, (index, key)|
        index ? out << "[#{index}]" : out << ".\"#{key.gsub('"', '\\"')}\""
      end
    end

    def bucket(points, max_points)
      return points if max_points <= 0 || points.size <= max_points

      first = points.first[0]
      width = (points.last[0] - first + 1).fdiv(max_points)
      points.group_by { |ts, _| ((ts - first) / width).floor }.values.map do |group|
        [group.sum { |ts, _| ts } / group.size, group.sum { |_, v| v }.fdiv(group.size)]
      end
    end
  end
end
