# frozen_string_literal: true

require "minitest/autorun"
require "logger"

$log ||= Logger.new(nil)

module Setting
  VALUES = {}

  def self.fetch(key, default = nil) = VALUES.fetch(key, default)

  def self.list(key, default = []) = VALUES.fetch(key, default)
end

require_relative "../lib/topic_registry"

class TopicRegistryTest < Minitest::Test
  def setup
    Setting::VALUES.clear
    TopicRegistry.reset!
  end

  def touch(topic, ts_ms, payload = "x", retained: false)
    TopicRegistry.touch(topic: topic, ts_ms: ts_ms, size: payload.bytesize, retained: retained, payload: payload)
  end

  def test_touch_reports_first_seen_and_counts
    assert_equal true, touch("a/b", 1_000)
    assert_equal false, touch("a/b", 2_000, "yy", retained: true)
    entry = TopicRegistry.get("a/b")
    assert_equal 2, entry[:count]
    assert_equal 1_000, entry[:first_seen_ms]
    assert_equal 2_000, entry[:last_seen_ms]
    assert_equal true, entry[:retained]
    assert_equal 2, entry[:last_size]
    assert_equal "yy", entry[:last_payload]
    assert_equal 1, TopicRegistry.size
  end

  def test_all_shape
    touch("b", 1_000)
    touch("a", 1_000)
    all = TopicRegistry.all
    assert_equal %w[a b], all.map { |e| e[:topic] }
    assert_equal %i[topic count rate bytes_rate first_seen_ms last_seen_ms retained last_size last_payload].sort,
                 all.first.keys.sort
  end

  def test_lru_eviction_at_max_topics
    Setting::VALUES["max_topics"] = 2
    touch("one", 1_000)
    touch("two", 1_000)
    touch("one", 2_000)
    touch("three", 3_000)
    assert_equal 2, TopicRegistry.size
    assert_nil TopicRegistry.get("two")
    refute_nil TopicRegistry.get("one")
  end

  def test_payload_truncated_to_max_payload_bytes
    Setting::VALUES["max_payload_bytes"] = 4
    touch("t", 1_000, "abcdefgh")
    entry = TopicRegistry.get("t")
    assert_equal "abcd", entry[:last_payload]
    assert_equal 8, entry[:last_size]
  end

  def test_truncation_mid_character_stays_text
    Setting::VALUES["max_payload_bytes"] = 4
    touch("t", 1_000, "abc€".b)
    assert_equal "abc", TopicRegistry.get("t")[:last_payload]
  end

  def test_binary_payload_is_nil
    touch("bin", 1_000, "\xFF\xFE\x00".b)
    assert_nil TopicRegistry.get("bin")[:last_payload]
    assert_equal 3, TopicRegistry.get("bin")[:last_size]
  end

  def test_rate_over_window
    Setting::VALUES["rate_window_s"] = 10
    now = Time.now.to_i
    20.times { |i| touch("r", ((now - 9) + (i / 2)) * 1000, "12345") }
    entry = TopicRegistry.get("r")
    assert_in_delta 2.0, entry[:rate], 0.21
    assert_in_delta 10.0, entry[:bytes_rate], 1.01
  end

  def test_rate_decays_after_window
    Setting::VALUES["rate_window_s"] = 5
    touch("old", (Time.now.to_i - 30) * 1000)
    assert_equal 0.0, TopicRegistry.get("old")[:rate]
  end

  def test_rate_ring_window
    ring = TopicRegistry::RateRing.new(3)
    ring.add(100, 10)
    ring.add(101, 10)
    ring.add(102, 10)
    assert_equal [1.0, 10.0], ring.rates(102)
    ring.add(103, 40)
    assert_equal [1.0, 20.0], ring.rates(103)
    assert_equal [0.0, 0.0], ring.rates(200)
  end

  def test_warm_seeds_from_store_rows
    rows = [
      { name: "x/1", first_seen_ms: 10, last_seen_ms: 50, retained: true, stored_count: 7 },
      { name: "x/2", first_seen_ms: 20, last_seen_ms: 30, retained: false, stored_count: 1 }
    ]
    assert_equal 2, TopicRegistry.warm(rows)
    entry = TopicRegistry.get("x/1")
    assert_equal 7, entry[:count]
    assert_equal 10, entry[:first_seen_ms]
    assert_equal 50, entry[:last_seen_ms]
    assert_equal true, entry[:retained]
    assert_nil entry[:last_payload]
    assert_equal 0.0, entry[:rate]
    assert_equal false, touch("x/1", 60)
    assert_equal 8, TopicRegistry.get("x/1")[:count]
  end

  def test_warm_keeps_most_recent_when_over_cap
    Setting::VALUES["max_topics"] = 1
    TopicRegistry.warm([{ name: "old", first_seen_ms: 1, last_seen_ms: 1, stored_count: 1 },
                        { name: "new", first_seen_ms: 1, last_seen_ms: 9, stored_count: 1 }])
    assert_equal ["new"], TopicRegistry.all.map { |e| e[:topic] }
  end
end
