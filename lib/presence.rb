# frozen_string_literal: true

require "json"

# Device online/offline state derived from presence_rules over the topic registry and history.
module Presence
  ONLINE_WORDS = %w[true 1 online on yes up connected].freeze

  class << self
    def rules
      raw = Setting.json("presence_rules", Setting::DEFAULT_PRESENCE_RULES)
      return warn_rules("is not an array") unless raw.is_a?(Array)

      raw.filter_map { |rule| normalise(rule) }
    end

    def devices
      active = rules
      now = now_ms
      TopicRegistry.all.filter_map { |entry| device_for(entry, active, now) }
                   .sort_by { |d| [d[:name].to_s, d[:label].to_s.downcase] }
    end

    def timeline(id:, from_ms:, to_ms:)
      found = locate(id.to_s)
      return [] unless found

      rule, entry = found
      rows = Store.history(topic: entry[:topic], from_ms: from_ms, to_ms: to_ms,
                           limit: Setting.fetch("timeline_max_rows", 5000)).reverse
      segments(rows, rule, horizon(to_ms))
    end

    private

    def now_ms = (Time.now.to_f * 1000).to_i

    def normalise(rule)
      return nil unless rule.is_a?(Hash)

      r = rule.transform_keys(&:to_s)
      return skip(r, "invalid pattern") unless TopicMatch.valid_filter?(r["pattern"].to_s)

      { name: (r["name"] || r["pattern"]).to_s, pattern: r["pattern"].to_s,
        id_segment: Integer(r["id_segment"]), online_path: blank_nil(r["online_path"]),
        label_path: blank_nil(r["label_path"]), stale_s: Integer(r["stale_s"]) }
    rescue ArgumentError, TypeError
      skip(r, "non-integer id_segment or stale_s")
    end

    def blank_nil(value) = value.to_s.empty? ? nil : value.to_s

    def skip(rule, reason)
      log_warn("[presence] skipping rule #{rule.inspect}: #{reason}")
      nil
    end

    def warn_rules(reason)
      log_warn("[presence] presence_rules #{reason}, ignoring")
      []
    end

    def log_warn(msg) = $log&.warn(msg)

    def match(entry, active)
      rule = active.find { |r| TopicMatch.match?(r[:pattern], entry[:topic]) }
      return nil unless rule

      id = entry[:topic].split("/")[rule[:id_segment]]
      id.nil? || id.empty? ? nil : [rule, id]
    end

    def device_for(entry, active, now)
      rule, id = match(entry, active)
      return nil unless rule

      parsed = parse(entry[:last_payload])
      flag = online_flag(parsed, rule)
      fresh = fresh?(entry[:last_seen_ms], rule, now)
      { id: id, name: rule[:name], label: label(parsed, rule) || id, online: flag && fresh,
        topic: entry[:topic], last_seen_ms: entry[:last_seen_ms],
        since_ms: since(entry, rule, flag, fresh), stale: flag && !fresh, fields: fields(parsed) }
    end

    def fresh?(last_seen_ms, rule, now) = !last_seen_ms.nil? && now - last_seen_ms <= rule[:stale_s] * 1000

    def fields(parsed) = parsed.is_a?(Hash) || parsed.is_a?(Array) ? Differ.flatten(parsed) : {}

    def label(parsed, rule)
      value = rule[:label_path] && dig(parsed, rule[:label_path])
      value.nil? || value.is_a?(Hash) || value.is_a?(Array) || value.to_s.empty? ? nil : value.to_s
    end

    def since(entry, rule, flag, fresh)
      return entry[:last_seen_ms] + (rule[:stale_s] * 1000) if flag && !fresh

      rows = Store.history(topic: entry[:topic], limit: Setting.fetch("history_default_limit", 200))
      run = rows.take_while { |row| online_flag(parse(row[:payload]), rule) == flag }
      run.empty? ? entry[:last_seen_ms] : run.last[:ts_ms]
    end

    def locate(id)
      active = rules
      TopicRegistry.all.each do |entry|
        rule, found = match(entry, active)
        return [rule, entry] if rule && found == id
      end
      nil
    end

    def horizon(to_ms) = to_ms ? [to_ms, now_ms].min : now_ms

    def segments(rows, rule, horizon)
      stale_ms = rule[:stale_s] * 1000
      segs = []
      rows.each_with_index do |row, i|
        open_segment(segs, row[:ts_ms], online_flag(parse(row[:payload]), rule))
        gap_end = rows[i + 1] ? rows[i + 1][:ts_ms] : horizon
        open_segment(segs, row[:ts_ms] + stale_ms, false) if segs.last[:online] && gap_end - row[:ts_ms] > stale_ms
      end
      segs
    end

    def open_segment(segs, ts, online)
      return if segs.last && segs.last[:online] == online

      segs.last[:to_ms] = ts if segs.last
      segs << { from_ms: ts, to_ms: nil, online: online }
    end

    def online_flag(parsed, rule)
      value = rule[:online_path] && (parsed.is_a?(Hash) || parsed.is_a?(Array)) ? dig(parsed, rule[:online_path]) : parsed
      truthy?(value)
    end

    def truthy?(value)
      case value
      when nil, false then false
      when Numeric then !value.zero?
      when String then ONLINE_WORDS.include?(value.strip.downcase)
      else true
      end
    end

    def parse(payload)
      return nil if payload.nil? || payload.empty?

      text = payload.dup.force_encoding(Encoding::UTF_8)
      return nil unless text.valid_encoding?

      Differ.classify(text) == :json ? JSON.parse(text) : text.strip
    rescue JSON::ParserError
      nil
    end

    def dig(json, path)
      path.scan(/[^.\[\]]+|\[\d+\]/).reduce(json) do |node, key|
        if key.start_with?("[") then node.is_a?(Array) ? node[key[1..-2].to_i] : nil
        else node.is_a?(Hash) ? node[key] : nil
        end
      end
    end
  end
end
