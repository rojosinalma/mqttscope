# frozen_string_literal: true

db_path = ENV.fetch("DATABASE_PATH") { abort "set DATABASE_PATH to a throwaway file" }
abort "refusing to test against #{db_path}" if db_path.include?("/data/")

require "json"
require "minitest/autorun"
require_relative "../lib/logger"
$log.level = Logger::ERROR
require_relative "../models/database"
require_relative "../models/setting"
require_relative "../lib/topic_match"
require_relative "../lib/sampling"

class SamplingTest < Minitest::Test
  def setup
    DB[:settings].delete
    Setting.seed_defaults!
    Sampling.reset!
  end

  def store?(topic, payload, ts) = Sampling.store?(topic: topic, payload: payload, ts_ms: ts)

  def test_dedup_then_interval
    Setting.set("default_min_interval_ms", 0)
    assert store?("a", "1", 0)
    refute store?("a", "1", 10)
    assert_equal :dup, Sampling.last_reason("a")
    assert store?("a", "2", 20)
    assert_nil Sampling.last_reason("a")
    assert store?("a", "1", 30)
  end

  def test_dedup_disabled
    Setting.set("dedup_enabled", false)
    Setting.set("default_min_interval_ms", 0)
    assert store?("a", "1", 0)
    assert store?("a", "1", 1)
  end

  def test_default_interval
    assert store?("t", "1", 0)
    refute store?("t", "2", 999)
    assert_equal :interval, Sampling.last_reason("t")
    assert store?("t", "3", 1000)
    assert store?("other", "1", 1)
  end

  def test_interval_drop_keeps_last_stored_payload
    assert store?("t", "A", 0)
    refute store?("t", "B", 10)
    assert store?("t", "B", 1000)
  end

  def test_rules
    Setting.set("sample_rules", [{ pattern: "esp32/+/data", min_interval_ms: 10_000 }, { pattern: "esp32/#", min_interval_ms: 0 }])
    assert_equal({ pattern: "esp32/+/data", min_interval_ms: 10_000 }, Sampling.rule_for("esp32/abc/data"))
    assert_equal 0, Sampling.rule_for("esp32/abc/status")[:min_interval_ms]
    assert_equal({ pattern: nil, min_interval_ms: 1000 }, Sampling.rule_for("zigbee/x"))

    assert store?("esp32/abc/data", "1", 0)
    refute store?("esp32/abc/data", "2", 9_999)
    assert store?("esp32/abc/data", "3", 10_000)
    assert store?("esp32/abc/status", "1", 0)
    assert store?("esp32/abc/status", "2", 1)
  end

  def test_sys_rule_only_matches_sys
    assert_equal 60_000, Sampling.rule_for("$SYS/broker/uptime")[:min_interval_ms]
    Setting.set("sample_rules", [{ pattern: "#", min_interval_ms: 5 }])
    assert_equal 1000, Sampling.rule_for("$SYS/broker/uptime")[:min_interval_ms]
  end

  def test_invalid_rules_are_skipped
    Setting.set("sample_rules", [{ pattern: "a/#/b", min_interval_ms: 5 }, { pattern: "ok/+", min_interval_ms: -1 },
                                 { pattern: "ok/+", min_interval_ms: "5" }, "junk", { pattern: "ok/+", min_interval_ms: 7 }])
    assert_equal [{ pattern: "ok/+", min_interval_ms: 7 }], Sampling.rules
    Setting.set("sample_rules", "{not json")
    assert_empty Sampling.rules
    Setting.set("sample_rules", { pattern: "x" })
    assert_empty Sampling.rules
  end

  def test_state_is_bounded
    Setting.set("max_topics", 2)
    Setting.set("default_min_interval_ms", 0)
    store?("a", "1", 0)
    store?("b", "1", 0)
    store?("a", "1", 1)
    store?("c", "1", 0)
    assert_equal 2, Sampling.size
    assert store?("b", "1", 2), "b was evicted, so its payload is no longer a dup"
    refute store?("c", "1", 3)
  end
end
