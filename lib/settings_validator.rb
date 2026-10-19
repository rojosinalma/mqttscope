# frozen_string_literal: true

require "json"

# Validates a POST /api/settings body and normalises it into the text values the
# settings table stores. Only keys present in Setting.defaults are accepted.
module SettingsValidator
  MASK = "••••"

  Result = Struct.new(:values, :errors) do
    def ok? = errors.empty?
  end

  INT_RANGES = {
    "mqtt_port" => 1..65_535,
    "mqtt_keepalive_s" => 1..65_535,
    "max_payload_bytes" => 1..(256 * 1024 * 1024),
    "default_min_interval_ms" => 0..(24 * 3600 * 1000),
    "retention_days" => 1..3650,
    "max_db_bytes" => (1024 * 1024)..(16 * 1024**4),
    "prune_interval_s" => 60..(7 * 86_400),
    "prune_batch" => 100..1_000_000,
    "prune_target_pct" => 50..100,
    "prune_merge_pages" => 0..10_000_000,
    "max_topics" => 100..10_000_000,
    "rate_window_s" => 6..86_400,
    "sse_max_clients" => 1..1000,
    "sse_idle_timeout_s" => 10..(7 * 86_400),
    "sse_heartbeat_s" => 1..600,
    "sse_queue_size" => 10..1_000_000,
    "history_default_limit" => 1..100_000,
    "search_default_limit" => 1..100_000,
    "api_max_limit" => 1..1_000_000,
    "series_default_points" => 1..100_000
  }.freeze

  BOOLEANS = %w[publish_enabled dedup_enabled].freeze
  TRUE_WORDS = ["true", "1", "on", "yes"].freeze
  FALSE_WORDS = ["false", "0", "off", "no"].freeze

  FILTER_LISTS = %w[mqtt_subscriptions].freeze
  INT_LISTS = { "reconnect_backoff_s" => 1..3600 }.freeze

  STRINGS = {
    "mqtt_host" => { min: 1, max: 253, pattern: /\A[^\s\/]+\z/ },
    "mqtt_user" => { min: 0, max: 256 },
    "mqtt_pass" => { min: 0, max: 1024 },
    "mqtt_client_id" => { min: 1, max: 128, pattern: /\A[^\s]+\z/ }
  }.freeze

  RULE_SHAPES = {
    "sample_rules" => {
      "pattern" => :filter, "min_interval_ms" => :non_negative_int
    },
    "presence_rules" => {
      "name" => :string, "pattern" => :filter, "id_segment" => :non_negative_int,
      "online_path" => :optional_string, "label_path" => :optional_string, "stale_s" => :positive_int
    }
  }.freeze

  module_function

  def known_keys = ::Setting.defaults.keys

  # -> Result(values: {key => stored text}, errors: {key => reason})
  def validate(params)
    return Result.new({}, { "_" => "Body must be a JSON object of settings" }) unless params.is_a?(Hash)
    return Result.new({}, { "_" => "No settings given" }) if params.empty?

    values = {}
    errors = {}
    params.each do |raw_key, raw|
      key = raw_key.to_s
      next if key == "mqtt_pass" && raw == MASK

      error, value = check(key, raw)
      error ? errors[key] = error : values[key] = value
    end
    cross_check(values, errors)
    Result.new(values, errors)
  end

  # Saves validated values; returns the keys whose stored value actually changed.
  def apply!(values)
    current = ::Setting.all_values
    changed = values.reject { |key, value| current[key] == value }.keys
    DB.transaction { values.each { |key, value| ::Setting.set(key, value) } }
    changed
  end

  def connection_change?(keys) = !(keys & ::Setting::CONNECTION_KEYS).empty?

  # Current values for display: defaults overlaid with stored values, secrets masked.
  def masked
    values = ::Setting.defaults.merge(::Setting.all_values.slice(*known_keys))
    ::Setting::SECRET_KEYS.each { |key| values[key] = MASK unless values[key].to_s.empty? }
    values
  end

  def check(key, raw)
    return ["unknown setting"] unless known_keys.include?(key)
    return ["must not be null"] if raw.nil?

    if INT_RANGES.key?(key) then check_int(raw, INT_RANGES[key])
    elsif BOOLEANS.include?(key) then check_bool(raw)
    elsif FILTER_LISTS.include?(key) then check_filter_list(raw)
    elsif INT_LISTS.key?(key) then check_int_list(raw, INT_LISTS[key])
    elsif STRINGS.key?(key) then check_string(raw, **STRINGS[key])
    elsif RULE_SHAPES.key?(key) then check_rules(raw, RULE_SHAPES[key])
    else check_by_default(raw, ::Setting.defaults[key])
    end
  end

  # Keys added to Setting.defaults without a rule here are validated by the shape of their default.
  def check_by_default(raw, default)
    case default.to_s
    when /\A\d+\z/ then check_int(raw, 0..(2**62))
    when "true", "false" then check_bool(raw)
    else ["has no validation rule; refusing to store it"]
    end
  end

  def check_int(raw, range)
    value = to_int(raw)
    return ["must be an integer"] if value.nil?
    return ["must be between #{range.min} and #{range.max}"] unless range.cover?(value)

    [nil, value.to_s]
  end

  def check_bool(raw)
    word = raw.to_s.strip.downcase
    return [nil, "true"] if raw == true || TRUE_WORDS.include?(word)
    return [nil, "false"] if raw == false || FALSE_WORDS.include?(word)

    ["must be true or false"]
  end

  def check_filter_list(raw)
    items = list(raw)
    return ["must be a comma list of topic filters"] if items.nil? || items.empty?

    bad = items.reject { |f| ::TopicMatch.valid_filter?(f) }
    return ["invalid topic filter(s): #{bad.join(', ')}"] unless bad.empty?

    [nil, items.join(",")]
  end

  def check_int_list(raw, range)
    items = list(raw)
    return ["must be a comma list of integers"] if items.nil? || items.empty?

    ints = items.map { |i| to_int(i) }
    return ["must be a comma list of integers"] if ints.any?(&:nil?)
    return ["each value must be between #{range.min} and #{range.max}"] unless ints.all? { |i| range.cover?(i) }

    [nil, ints.join(",")]
  end

  def check_string(raw, min:, max:, pattern: nil)
    return ["must be a string"] unless raw.is_a?(String)

    value = raw.strip
    return ["must be #{min}–#{max} characters"] unless value.length.between?(min, max)
    return ["contains invalid characters"] if pattern && !value.empty? && !pattern.match?(value)
    return ["must not contain NUL"] if value.include?("\0")

    [nil, value]
  end

  def check_rules(raw, shape)
    rules = raw.is_a?(String) ? JSON.parse(raw) : raw
    return ["must be a JSON array of objects"] unless rules.is_a?(Array) && rules.all?(Hash)

    rules = rules.map { |rule| rule.transform_keys(&:to_s) }
    rules.each_with_index do |rule, i|
      error = rule_error(rule, shape)
      return ["rule #{i + 1}: #{error}"] if error
    end
    [nil, JSON.generate(rules)]
  rescue JSON::ParserError => e
    ["is not valid JSON (#{e.message.lines.first.to_s.strip})"]
  end

  def rule_error(rule, shape)
    unknown = rule.keys - shape.keys
    return "unknown key(s) #{unknown.join(', ')}" unless unknown.empty?

    shape.each do |field, type|
      error = field_error(rule[field], type)
      return "#{field} #{error}" if error
    end
    nil
  end

  def field_error(value, type)
    case type
    when :filter then "must be a valid topic filter" unless value.is_a?(String) && ::TopicMatch.valid_filter?(value)
    when :string then "must be a non-empty string" unless value.is_a?(String) && !value.strip.empty?
    when :optional_string then "must be a string" unless value.nil? || value.is_a?(String)
    when :non_negative_int then "must be an integer >= 0" unless value.is_a?(Integer) && value >= 0
    when :positive_int then "must be an integer >= 1" unless value.is_a?(Integer) && value >= 1
    end
  end

  def cross_check(values, errors)
    effective = ::Setting.defaults.merge(::Setting.all_values).merge(values)
    heartbeat = to_int(effective["sse_heartbeat_s"])
    idle = to_int(effective["sse_idle_timeout_s"])
    return unless heartbeat && idle && heartbeat >= idle
    return if errors.key?("sse_heartbeat_s")

    errors["sse_heartbeat_s"] = "must be smaller than sse_idle_timeout_s (#{idle})"
    values.delete("sse_heartbeat_s")
  end

  def to_int(raw)
    return raw if raw.is_a?(Integer)
    return nil unless raw.is_a?(String)

    Integer(raw.strip, 10)
  rescue ArgumentError
    nil
  end

  def list(raw)
    items = raw.is_a?(Array) ? raw.map(&:to_s) : (raw.is_a?(String) ? raw.split(",") : nil)
    items&.map(&:strip)&.reject(&:empty?)
  end
end
