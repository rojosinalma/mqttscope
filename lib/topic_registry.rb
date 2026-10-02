# frozen_string_literal: true

# In-memory view of every topic seen on the broker: counts, rates, last payload.
# The state lives in a global so it survives a reload of this file in development.
module TopicRegistry
  # Per-second counters over a sliding window, with running totals so reads are O(1)
  # once the window has been advanced.
  class RateRing
    attr_reader :window

    def initialize(window)
      @window = [window.to_i, 1].max
      @counts = Array.new(@window, 0)
      @bytes = Array.new(@window, 0)
      @total = 0
      @total_bytes = 0
      @head = nil
      @started = nil
    end

    def add(sec, bytes)
      sec = advance(sec)
      i = sec % @window
      @counts[i] += 1
      @bytes[i] += bytes
      @total += 1
      @total_bytes += bytes
    end

    # [msgs/s, bytes/s]; before a full window has elapsed the divisor is the elapsed span.
    def rates(sec)
      return [0.0, 0.0] if @started.nil?

      sec = advance(sec)
      span = (sec - @started + 1).clamp(1, @window)
      [@total.fdiv(span), @total_bytes.fdiv(span)]
    end

    private

    def advance(sec)
      @started ||= sec
      @head ||= sec
      return @head if sec <= @head

      if sec - @head >= @window
        clear if @total.positive?
      else
        ((@head + 1)..sec).each do |s|
          i = s % @window
          @total -= @counts[i]
          @total_bytes -= @bytes[i]
          @counts[i] = 0
          @bytes[i] = 0
        end
      end
      @head = sec
    end

    def clear
      @counts.fill(0)
      @bytes.fill(0)
      @total = 0
      @total_bytes = 0
    end
  end

  SETTINGS_TTL_MS = 1000

  $topic_registry_state ||= { lock: Mutex.new, entries: {}, settings: {}, settings_at: 0 }

  class << self
    # Returns true when the topic was not in the registry before.
    def touch(topic:, ts_ms:, size:, retained:, payload:)
      max_bytes = setting("max_payload_bytes", 262_144)
      truncated = payload.bytesize > max_bytes
      kept = truncated ? payload.byteslice(0, max_bytes) : payload
      window = setting("rate_window_s", 60)
      max_topics = setting("max_topics", 20_000)

      synchronize do
        entry = entries.delete(topic)
        created = entry.nil?
        entry ||= new_entry(topic, ts_ms)
        entry[:count] += 1
        entry[:last_seen_ms] = ts_ms
        entry[:retained] = retained ? true : false
        entry[:last_size] = size
        entry[:last_payload] = kept
        entry[:truncated] = truncated
        entry[:ring] = RateRing.new(window) if entry[:ring].nil? || entry[:ring].window != window
        entry[:ring].add(ts_ms / 1000, size)
        entries[topic] = entry
        evict(max_topics)
        created
      end
    end

    def all
      now = Time.now.to_i
      synchronize { entries.values.map { |e| snapshot(e, now) } }.sort_by! { |e| e[:topic] }
    end

    def get(topic)
      now = Time.now.to_i
      synchronize do
        entry = entries[topic]
        entry && snapshot(entry, now)
      end
    end

    def size = synchronize { entries.size }

    def warm(rows)
      max_topics = setting("max_topics", 20_000)
      seeded = Array(rows).sort_by { |r| r[:last_seen_ms].to_i }.last(max_topics)
      synchronize do
        seeded.each do |row|
          name = row[:name]
          next if name.nil? || entries.key?(name)

          entry = new_entry(name, row[:first_seen_ms].to_i)
          entry[:count] = row[:stored_count].to_i
          entry[:last_seen_ms] = row[:last_seen_ms].to_i
          entry[:retained] = row[:retained] ? true : false
          entries[name] = entry
        end
        evict(max_topics)
      end
      $log.info "[mqtt] topic registry warmed with #{seeded.size} topics"
      seeded.size
    end

    # UTF-8 copy of bytes, or nil when they are not text. A truncated payload may end
    # mid-character, so up to 3 trailing bytes are dropped before giving up.
    def text_or_nil(bytes, truncated: false)
      return nil if bytes.nil?

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      return text if text.valid_encoding?
      return nil unless truncated

      (1..3).each do |cut|
        shorter = text.byteslice(0, text.bytesize - cut)
        return shorter if shorter.valid_encoding?
      end
      nil
    end

    def reset!
      synchronize do
        entries.clear
        state[:settings] = {}
        state[:settings_at] = 0
      end
    end

    private

    def state = $topic_registry_state

    def entries = state[:entries]

    def synchronize(&) = state[:lock].synchronize(&)

    def new_entry(topic, ts_ms)
      { topic: topic, count: 0, first_seen_ms: ts_ms, last_seen_ms: ts_ms, retained: false,
        last_size: nil, last_payload: nil, truncated: false, ring: nil }
    end

    def evict(max_topics)
      entries.shift while entries.size > max_topics
    end

    def snapshot(entry, now_s)
      rate, bytes_rate = entry[:ring] ? entry[:ring].rates(now_s) : [0.0, 0.0]
      { topic: entry[:topic], count: entry[:count], rate: rate.round(3), bytes_rate: bytes_rate.round(1),
        first_seen_ms: entry[:first_seen_ms], last_seen_ms: entry[:last_seen_ms], retained: entry[:retained],
        last_size: entry[:last_size], last_payload: text_or_nil(entry[:last_payload], truncated: entry[:truncated]) }
    end

    # touch runs per message; settings are re-read at most once a second instead of per call.
    def setting(key, default)
      now = (Time.now.to_f * 1000).to_i
      cache = state[:settings]
      if now - state[:settings_at] > SETTINGS_TTL_MS
        cache = {}
        state[:settings] = cache
        state[:settings_at] = now
      end
      cache.fetch(key) { cache[key] = Setting.fetch(key, default) }
    end
  end
end
