# frozen_string_literal: true

class Setting < Sequel::Model(:settings)
  unrestrict_primary_key

  DEFAULT_SAMPLE_RULES = [
    { pattern: "$SYS/#", min_interval_ms: 60_000 }
  ].freeze

  DEFAULT_PRESENCE_RULES = [].freeze

  SECRET_KEYS = %w[mqtt_pass].freeze
  CONNECTION_KEYS = %w[mqtt_host mqtt_port mqtt_user mqtt_pass mqtt_client_id mqtt_subscriptions mqtt_keepalive_s].freeze

  # Connection values are seeded from the environment on first boot only; afterwards the DB wins.
  def self.defaults
    {
      "mqtt_host" => ENV.fetch("MQTT_HOST", "mosquitto"),
      "mqtt_port" => ENV.fetch("MQTT_PORT", "1883"),
      "mqtt_user" => ENV.fetch("MQTT_USER", ""),
      "mqtt_pass" => ENV.fetch("MQTT_PASS", ""),
      "mqtt_client_id" => ENV.fetch("MQTT_CLIENT_ID", "mqttscope"),
      "mqtt_subscriptions" => "#,$SYS/#",
      "mqtt_keepalive_s" => "30",
      "reconnect_backoff_s" => "2,5,10,30,60",
      "publish_enabled" => "true",
      "max_payload_bytes" => "262144",
      "dedup_enabled" => "true",
      "default_min_interval_ms" => "1000",
      "sample_rules" => JSON.generate(DEFAULT_SAMPLE_RULES),
      "retention_days" => "7",
      "max_db_bytes" => (10 * 1024 * 1024 * 1024).to_s,
      "prune_interval_s" => "3600",
      "prune_batch" => "500",
      "prune_target_pct" => "90",
      "prune_merge_pages" => "10000",
      "max_topics" => "20000",
      "rate_window_s" => "60",
      "sse_max_clients" => "12",
      "sse_idle_timeout_s" => "300",
      "sse_heartbeat_s" => "15",
      "sse_queue_size" => "500",
      "presence_rules" => JSON.generate(DEFAULT_PRESENCE_RULES),
      "history_default_limit" => "200",
      "search_default_limit" => "100",
      "series_max_rows" => "50000",
      "search_max_rows" => "20000",
      "api_max_limit" => "5000",
      "series_default_points" => "500",
      "timeline_max_rows" => "5000",
      "diff_max_lines" => "2000",
      "ingest_max_backlog" => "10000",
      "publish_echo_ttl_s" => "10"
    }
  end

  # Values are stored as text and cast to the type of the given default.
  def self.fetch(key, default = nil)
    row = self[key.to_s]
    return default if row.nil? || row.value.nil?

    cast(row.value, default)
  end

  def self.set(key, value)
    stored = value.is_a?(Array) || value.is_a?(Hash) ? JSON.generate(value) : value.to_s
    dataset.insert_conflict(:replace).insert(key: key.to_s, value: stored)
    stored
  end

  def self.all_values = dataset.to_hash(:key, :value)

  def self.seed_defaults!
    defaults.each { |key, value| dataset.insert_conflict(:ignore).insert(key: key, value: value) }
  end

  def self.json(key, default = [])
    JSON.parse(fetch(key, JSON.generate(default)))
  rescue JSON::ParserError => e
    $log.warn "[settings] #{key} is not valid JSON (#{e.message}), using default"
    default
  end

  def self.list(key, default = [])
    fetch(key, default.join(",")).split(",").map(&:strip).reject(&:empty?)
  end

  def self.cast(value, default)
    case default
    when Integer then Integer(value, 10)
    when Float then Float(value)
    when true, false then value == "true"
    when Array then value.split(",").map(&:strip).reject(&:empty?)
    else value
    end
  rescue ArgumentError, TypeError
    $log.warn "[settings] invalid value #{value.inspect}, using default #{default.inspect}"
    default
  end
end
