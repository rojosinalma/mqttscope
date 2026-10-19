# frozen_string_literal: true

class App
  hash_branch "api" do |r|
    r.get "topics" do
      json_ok("ok", topics: api_merged_topics)
    end

    r.on "messages" do
      r.get Integer do |id|
        message = ::Store.message(id) or halt_json(404, "Message #{id} not found")
        json_ok("ok", message: message)
      end

      r.get true do
        topic = api_required("topic")
        messages = ::Store.history(topic: topic, from_ms: int_param("from_ms", nil, min: 0),
                                   to_ms: int_param("to_ms", nil, min: 0), limit: api_limit("history_default_limit", 200),
                                   before_id: int_param("before_id", nil, min: 1))
        json_ok("ok", messages: messages)
      end
    end

    r.get "diff" do
      id = int_param("id", nil, min: 1) or halt_json(400, "id is required")
      to = ::Store.message(id) or halt_json(404, "Message #{id} not found")
      from = ::Store.previous(topic: to[:topic], before_id: id)
      json_ok("ok", diff: ::Differ.diff(from && from[:payload], to[:payload]), from: from, to: to)
    end

    r.get "series" do
      json_ok("ok", points: api_series)
    end

    r.get "paths" do
      json_ok("ok", paths: ::Differ.numeric_paths(api_last_payload(api_required("topic"))))
    end

    r.get "search" do
      q = api_required("q")
      filter = api_filter_param("topic")
      results = ::Store.search(q: q, topic_filter: filter, from_ms: int_param("from_ms", nil, min: 0),
                               to_ms: int_param("to_ms", nil, min: 0), limit: api_limit("search_default_limit", 100))
      json_ok("ok", results: results)
    end

    r.on "stats" do
      r.get "series" do
        json_ok("ok", points: api_series)
      end

      r.get true do
        json_ok("ok", ingest: ::Ingest.status, db: ::Store.stats, sys: ::Store.sys_latest,
                      sse_clients: ::Bus.client_count, prune: ::Pruner.last_run)
      end
    end

    # Liveness for the container health check: cheap on purpose (no table scans).
    r.get "healthz" do
      DB.get(1)
      json_ok("ok", connected: ::Ingest.status[:connected], prune_running: ::Pruner.running?)
    end

    r.on "devices" do
      r.get String, "timeline" do |id|
        from_ms, to_ms = api_window
        json_ok("ok", timeline: ::Presence.timeline(id: id, from_ms: from_ms, to_ms: to_ms))
      end

      r.get true do
        json_ok("ok", devices: ::Presence.devices)
      end
    end

    r.post "publish" do
      halt_json(403, "Publishing is disabled (publish_enabled=false)") unless ::Setting.fetch("publish_enabled", true)

      body = api_body
      topic = body["topic"].to_s
      halt_json(400, "topic must be a concrete topic (no wildcards, not empty)") unless ::TopicMatch.valid_topic?(topic)
      payload = api_publish_payload(body["payload"])
      retain = api_bool(body["retain"], "retain")
      qos = api_qos(body["qos"])

      begin
        ::Ingest.publish(topic: topic, payload: payload, retain: retain, qos: qos)
      rescue ::Ingest::NotConnected => e
        $log.warn "[http] publish #{topic} refused: broker not connected (#{e.message})"
        halt_json(503, "Broker not connected: #{e.message}")
      rescue ArgumentError => e
        $log.warn "[http] publish #{topic} rejected: #{e.message}"
        halt_json(400, "Publish rejected: #{e.message}")
      end
      $log.info "[http] publish #{topic} bytes=#{payload.bytesize} retain=#{retain} qos=#{qos} from=#{r.ip}"
      json_ok("Published")
    end

    r.on "settings" do
      r.get true do
        json_ok("ok", settings: ::SettingsValidator.masked)
      end

      r.post true do
        result = ::SettingsValidator.validate(api_body)
        halt_json(400, "Invalid settings: #{result.errors.map { |k, v| "#{k} #{v}" }.join('; ')}", errors: result.errors) unless result.ok?

        changed = ::SettingsValidator.apply!(result.values)
        reconnect = ::SettingsValidator.connection_change?(changed)
        $log.info "[http] settings saved changed=#{changed.join(',')}#{' (reconnecting)' if reconnect}"
        ::Ingest.reconnect! if reconnect
        json_ok(changed.empty? ? "No changes" : "Saved #{changed.size} setting(s)", changed: changed, reconnecting: reconnect)
      end
    end

    r.post "prune" do
      result = ::Pruner.run_now
      json_ok(result ? "Pruned #{result[:deleted_by_age].to_i + result[:deleted_by_size].to_i} message(s)" : "Prune already running",
              prune: result)
    end

    r.post "reconnect" do
      ::Ingest.reconnect!
      $log.info "[http] reconnect requested from=#{r.ip}"
      json_ok("Reconnecting")
    end

    r.get "stream" do
      filters = api_list_param("topics", ["#"])
      bad = filters.reject { |f| ::TopicMatch.valid_filter?(f) }
      halt_json(400, "Invalid topic filter(s): #{bad.join(', ')}") unless bad.empty?

      heartbeat_s = ::Setting.fetch("sse_heartbeat_s", 15)
      idle_timeout_s = ::Setting.fetch("sse_idle_timeout_s", 300)
      sub = ::Bus.subscribe(filters: filters, max_queue: ::Setting.fetch("sse_queue_size", 500),
                            max_clients: ::Setting.fetch("sse_max_clients", 20))
      halt_json(503, "Too many live streams") unless sub

      release = ::SseStream.releaser(sub)
      begin
        response["content-type"] = "text/event-stream"
        response["cache-control"] = "no-cache"
        response["x-accel-buffering"] = "no"
        response["connection"] = "keep-alive"
        stream(callback: release) do |out|
          ::SseStream.pump(out, sub, heartbeat_s: heartbeat_s, idle_timeout_s: idle_timeout_s)
        ensure
          release.call
        end
      rescue StandardError
        release.call
        raise
      end
    end
  end

  private

  def api_now_ms = (Time.now.to_f * 1000).to_i

  def api_required(name)
    value = request.params[name].to_s.strip
    halt_json(400, "#{name} is required") if value.empty?
    value
  end

  def api_list_param(name, default)
    items = request.params[name].to_s.split(",").map(&:strip).reject(&:empty?)
    items.empty? ? default : items
  end

  def api_filter_param(name)
    value = request.params[name].to_s.strip
    return nil if value.empty?

    halt_json(400, "#{name} is not a valid topic filter") unless ::TopicMatch.valid_filter?(value)
    value
  end

  def api_limit(default_key, fallback)
    int_param("limit", ::Setting.fetch(default_key, fallback), min: 1, max: ::Setting.fetch("api_max_limit", 5000))
  end

  # from_ms/to_ms default to the whole retention window ending now.
  def api_window
    to_ms = int_param("to_ms", api_now_ms, min: 0)
    from_ms = int_param("from_ms", to_ms - (::Setting.fetch("retention_days", 7) * 86_400_000), min: 0)
    halt_json(400, "from_ms must be <= to_ms") if from_ms > to_ms
    [from_ms, to_ms]
  end

  def api_series
    topic = api_required("topic")
    path = request.params["path"].to_s
    path = "" if path == "."
    from_ms, to_ms = api_window
    max_points = int_param("max_points", ::Setting.fetch("series_default_points", 500),
                           min: 1, max: ::Setting.fetch("api_max_limit", 5000))
    ::Store.series(topic: topic, path: path, from_ms: from_ms, to_ms: to_ms, max_points: max_points)
  end

  def api_last_payload(topic)
    entry = ::TopicRegistry.get(topic)
    return entry[:last_payload] if entry && entry[:last_payload]

    ::Store.history(topic: topic, limit: 1).first&.[](:payload)
  end

  # Registry entries carry live rates; topics rows carry stored counts. Topics only in the DB
  # (evicted from the LRU registry) still show up, with zero rates.
  def api_merged_topics
    stored = ::Store.topics.to_h { |row| [(row[:topic] || row[:name]).to_s, row] }
    live = ::TopicRegistry.all.map do |entry|
      entry.merge(stored_count: stored.delete(entry[:topic].to_s)&.[](:stored_count).to_i)
    end
    cold = stored.map do |name, row|
      { topic: name, count: 0, rate: 0.0, bytes_rate: 0.0, first_seen_ms: row[:first_seen_ms],
        last_seen_ms: row[:last_seen_ms], retained: row[:retained] ? true : false, last_size: nil,
        last_payload: nil, stored_count: row[:stored_count].to_i }
    end
    (live + cold).sort_by { |t| t[:topic].to_s }
  end

  def api_body
    body = request.POST
    halt_json(400, "Body must be a JSON object") unless body.is_a?(Hash)
    body
  end

  def api_publish_payload(raw)
    payload = case raw
              when nil then ""
              when String then raw
              when Hash, Array, Numeric, true, false then JSON.generate(raw)
              else halt_json(400, "payload must be a string or JSON value")
              end
    max = ::Setting.fetch("max_payload_bytes", 262_144)
    halt_json(413, "payload is #{payload.bytesize} bytes, max_payload_bytes is #{max}") if payload.bytesize > max
    payload
  end

  def api_bool(raw, name)
    return false if raw.nil? || raw == false || raw == "false" || raw == "0" || raw == ""
    return true if raw == true || raw == "true" || raw == "1" || raw == "on"

    halt_json(400, "#{name} must be true or false")
  end

  def api_qos(raw)
    return 0 if raw.nil? || raw == ""

    qos = Integer(raw.to_s, 10)
    halt_json(400, "qos must be 0, 1 or 2") unless (0..2).cover?(qos)
    qos
  rescue ArgumentError
    halt_json(400, "qos must be 0, 1 or 2")
  end
end
