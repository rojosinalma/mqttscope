# frozen_string_literal: true

require "digest"
require "json"

# Decides per received message whether it is stored: dedup against the last stored payload,
# then the min-interval of the first matching sample rule.
module Sampling
  KEYS = %w[dedup_enabled default_min_interval_ms max_topics sample_rules].freeze

  @mutex = Mutex.new
  @state = {}
  @rules_raw = nil
  @rules = [].freeze

  class << self
    def store?(topic:, payload:, ts_ms:)
      conf = settings
      digest = Digest::MD5.digest(payload.to_s.b)
      interval = rule_for(topic, conf)[:min_interval_ms]

      @mutex.synchronize do
        state = touch(topic, conf[:max_topics])
        state[:reason] =
          if conf[:dedup] && state[:digest] == digest then :dup
          elsif state[:last_stored_ms] && ts_ms - state[:last_stored_ms] < interval then :interval
          end
        next false if state[:reason]

        state[:digest] = digest
        state[:last_stored_ms] = ts_ms
        true
      end
    end

    def last_reason(topic) = @mutex.synchronize { @state[topic]&.dig(:reason) }

    def rule_for(topic, conf = settings)
      rules_from(conf[:rules_raw]).find { |rule| TopicMatch.match?(rule[:pattern], topic) } ||
        { pattern: nil, min_interval_ms: conf[:default_interval] }
    end

    def rules = rules_from(settings[:rules_raw])

    def size = @mutex.synchronize { @state.size }

    def reset! = @mutex.synchronize { @state.clear }

    private

    def touch(topic, max)
      state = @state.delete(topic) || {}
      @state[topic] = state
      @state.shift while @state.size > max
      state
    end

    def settings
      raw = Setting.where(key: KEYS).to_hash(:key, :value)
      {
        dedup: Setting.cast(raw.fetch("dedup_enabled", "true"), true),
        default_interval: Setting.cast(raw.fetch("default_min_interval_ms", "1000"), 1000),
        max_topics: [Setting.cast(raw.fetch("max_topics", "20000"), 20_000), 1].max,
        rules_raw: raw.fetch("sample_rules", "[]")
      }
    end

    def rules_from(raw)
      return @rules if raw == @rules_raw

      parsed = parse_rules(raw)
      @rules_raw = raw
      @rules = parsed.freeze
    end

    def parse_rules(raw)
      list = JSON.parse(raw.to_s)
      unless list.is_a?(Array)
        $log.warn "[store] sample_rules is not a JSON array, ignoring it"
        return []
      end

      list.filter_map do |entry|
        rule = valid_rule(entry)
        $log.warn "[store] sample_rules: skipping invalid entry #{entry.inspect}" unless rule
        rule
      end
    rescue JSON::ParserError => e
      $log.warn "[store] sample_rules is not valid JSON (#{e.message}), ignoring it"
      []
    end

    def valid_rule(entry)
      return unless entry.is_a?(Hash)

      pattern = entry["pattern"]
      interval = entry["min_interval_ms"]
      return unless pattern.is_a?(String) && TopicMatch.valid_filter?(pattern)
      return unless interval.is_a?(Integer) && interval >= 0

      { pattern: pattern, min_interval_ms: interval }.freeze
    end
  end
end
