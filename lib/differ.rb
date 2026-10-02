# frozen_string_literal: true

require "json"

# Human-readable diff between two consecutive payloads of one topic. Pure: no DB access.
module Differ
  JSON_START = /\A\s*[{\["\-0-9tfn]/
  OPS = %w[changed added removed].freeze

  class << self
    def classify(payload)
      return :empty if payload.nil? || payload.empty?

      text = utf8(payload)
      return :binary unless text.valid_encoding?

      parse_json(text) == :invalid ? :text : :json
    end

    def diff(old_payload, new_payload)
      old_payload = nil if old_payload&.empty?
      new_payload = nil if new_payload&.empty?
      return same if bytes(old_payload) == bytes(new_payload)

      kinds = [old_payload, new_payload].map { |p| classify(p) }
      return binary_diff(old_payload, new_payload) if kinds.include?(:binary)
      return json_diff(old_payload, new_payload) if kinds.all? { |k| %i[json empty].include?(k) }

      text_diff(old_payload, new_payload)
    end

    def flatten(json, prefix = "", out = {})
      case json
      when Hash
        return out.merge!(prefix => {}) if json.empty? && !prefix.empty?

        json.each { |k, v| flatten(v, join_key(prefix, k), out) }
      when Array
        return out.merge!(prefix => []) if json.empty? && !prefix.empty?

        json.each_with_index { |v, i| flatten(v, "#{prefix}[#{i}]", out) }
      else
        out[prefix] = json
      end
      out
    end

    def numeric_paths(payload)
      return [] unless classify(payload) == :json

      flatten(parse_json(utf8(payload))).select { |_, v| v.is_a?(Integer) || v.is_a?(Float) }.keys.sort
    end

    private

    def same = { kind: "same", summary: "no change", changes: [] }

    def utf8(payload) = payload.dup.force_encoding(Encoding::UTF_8)

    def bytes(payload) = payload&.b

    def parse_json(text)
      return :invalid unless text.match?(JSON_START) && text.bytesize <= max_parse_bytes

      JSON.parse(text)
    rescue JSON::ParserError, EncodingError
      :invalid
    end

    def max_parse_bytes = setting("max_payload_bytes", 262_144) || Float::INFINITY

    def max_lines = setting("diff_max_lines", 2000) || 2000

    def setting(key, default)
      return nil unless defined?(::Setting) && ::Setting.respond_to?(:fetch)

      ::Setting.fetch(key, default)
    end

    def join_key(prefix, key) = prefix.empty? ? key.to_s : "#{prefix}.#{key}"

    def result(kind, changes, summary = nil)
      { kind: kind, summary: summary || count_summary(changes), changes: changes }
    end

    def count_summary(changes)
      counts = changes.map { |c| c[:op] }.tally
      parts = OPS.filter_map { |op| "#{counts[op]} #{op}" if counts[op] }
      parts.empty? ? "no change" : parts.join(", ")
    end

    # JSON

    def json_diff(old_payload, new_payload)
      old_json = old_payload && parse_json(utf8(old_payload))
      new_json = new_payload && parse_json(utf8(new_payload))
      changes = []
      if old_payload.nil? then leaves(new_json, "", "added", changes)
      elsif new_payload.nil? then leaves(old_json, "", "removed", changes)
      else compare(old_json, new_json, "", changes)
      end
      changes.empty? ? same : result("json", changes)
    end

    def compare(old_v, new_v, path, changes)
      if old_v.is_a?(Hash) && new_v.is_a?(Hash) then compare_hash(old_v, new_v, path, changes)
      elsif old_v.is_a?(Array) && new_v.is_a?(Array) then compare_array(old_v, new_v, path, changes)
      elsif !equal_values?(old_v, new_v)
        changes << { path: path, op: "changed", from: old_v, to: new_v }
      end
    end

    def compare_hash(old_h, new_h, path, changes)
      (old_h.keys | new_h.keys).each do |key|
        sub = join_key(path, key)
        if !new_h.key?(key) then leaves(old_h[key], sub, "removed", changes)
        elsif !old_h.key?(key) then leaves(new_h[key], sub, "added", changes)
        else compare(old_h[key], new_h[key], sub, changes)
        end
      end
    end

    def compare_array(old_a, new_a, path, changes)
      [old_a.size, new_a.size].max.times do |i|
        sub = "#{path}[#{i}]"
        if i >= new_a.size then leaves(old_a[i], sub, "removed", changes)
        elsif i >= old_a.size then leaves(new_a[i], sub, "added", changes)
        else compare(old_a[i], new_a[i], sub, changes)
        end
      end
    end

    def equal_values?(a, b) = a == b && a.class == b.class

    def leaves(json, path, op, changes)
      flatten(json, path).each do |p, v|
        changes << (op == "added" ? { path: p, op: op, from: nil, to: v } : { path: p, op: op, from: v, to: nil })
      end
    end

    # Text

    def text_diff(old_payload, new_payload)
      old_lines = lines(old_payload)
      new_lines = lines(new_payload)
      head = common_prefix(old_lines, new_lines)
      tail = common_prefix(old_lines.drop(head).reverse, new_lines.drop(head).reverse)
      old_mid = old_lines[head...(old_lines.size - tail)]
      new_mid = new_lines[head...(new_lines.size - tail)]
      return too_large(old_mid, new_mid) if [old_mid.size, new_mid.size].max > max_lines

      changes = group_ops(lcs_ops(old_mid, new_mid), old_mid, new_mid, head)
      changes.empty? ? same : result("text", changes)
    end

    def lines(payload) = payload.nil? ? [] : utf8(payload).scrub.split("\n", -1)

    def common_prefix(a, b)
      n = 0
      n += 1 while n < a.size && n < b.size && a[n] == b[n]
      n
    end

    def too_large(old_mid, new_mid)
      result("text", [], "#{old_mid.size} → #{new_mid.size} lines changed (too large to diff line by line)")
    end

    def lcs_ops(a, b)
      table = lcs_table(a, b)
      ops = []
      i = a.size
      j = b.size
      while i.positive? || j.positive?
        if i.positive? && j.positive? && a[i - 1] == b[j - 1]
          ops << :eq
          i -= 1
          j -= 1
        elsif j.positive? && (i.zero? || table[i][j - 1] >= table[i - 1][j])
          ops << :ins
          j -= 1
        else
          ops << :del
          i -= 1
        end
      end
      ops.reverse
    end

    def lcs_table(a, b)
      table = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
      a.each_with_index do |x, i|
        row = table[i]
        nxt = table[i + 1]
        b.each_with_index { |y, j| nxt[j + 1] = x == y ? row[j] + 1 : [nxt[j], row[j + 1]].max }
      end
      table
    end

    def group_ops(ops, a, b, offset)
      changes = []
      i = 0
      j = 0
      ops.chunk_while { |x, y| x == y || (x == :del && y == :ins) || (x == :ins && y == :ins) }.each do |run|
        if run.first == :eq
          i += run.size
          j += run.size
          next
        end
        dels = run.count(:del)
        ins = run.count(:ins)
        [dels, ins].max.times do |k|
          changes << line_change(k < dels ? a[i + k] : nil, k < ins ? b[j + k] : nil,
                                 offset + 1 + (k < ins ? j + k : i + k))
        end
        i += dels
        j += ins
      end
      changes
    end

    def line_change(from, to, line)
      op = if from.nil? then "added"
           elsif to.nil? then "removed"
           else "changed"
           end
      { line: line, op: op, from: from, to: to }
    end

    # Binary

    def binary_diff(old_payload, new_payload)
      old_size = old_payload&.bytesize || 0
      new_size = new_payload&.bytesize || 0
      delta = new_size - old_size
      sign = delta.positive? ? "+" : ""
      summary = old_payload.nil? ? "#{new_size} bytes" : "#{old_size} → #{new_size} bytes (#{sign}#{delta})"
      result("binary", [], "binary, #{summary}")
    end
  end
end
