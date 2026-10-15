# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../lib/topic_match"
require_relative "../lib/differ"

unless defined?(Setting)
  module Setting
    DEFAULT_PRESENCE_RULES = [].freeze

    class << self
      attr_accessor :values

      def fetch(key, default = nil) = values.fetch(key, default)

      def json(key, default = [])
        values.key?(key) ? JSON.parse(values[key]) : default
      end
    end
  end
end

unless defined?(TopicRegistry)
  module TopicRegistry
    class << self
      attr_accessor :entries

      def all = entries
    end
  end
end

unless defined?(Store)
  module Store
    class << self
      attr_accessor :rows, :calls

      def history(topic:, from_ms: nil, to_ms: nil, limit: 200, before_id: nil)
        calls << { topic: topic, from_ms: from_ms, to_ms: to_ms, limit: limit }
        rows.fetch(topic, [])
            .select { |r| (from_ms.nil? || r[:ts_ms] >= from_ms) && (to_ms.nil? || r[:ts_ms] <= to_ms) }
            .sort_by { |r| -r[:ts_ms] }.first(limit)
      end
    end
  end
end

require_relative "../lib/presence"

class PresenceTest < Minitest::Test
  NOW = 10_000_000

  def setup
    Setting.values = {}
    TopicRegistry.entries = []
    Store.rows = {}
    Store.calls = []
    Presence.singleton_class.send(:define_method, :now_ms) { NOW }
  end

  def entry(topic, payload, last_seen_ms)
    { topic: topic, last_payload: payload, last_seen_ms: last_seen_ms, first_seen_ms: 0, retained: false }
  end

  def msg(ts_ms, payload) = { ts_ms: ts_ms, payload: payload }

  def at_now = yield

  ESP32_RULE = { "name" => "esp32", "pattern" => "esp32/+/status", "id_segment" => 1,
                 "online_path" => "online", "label_path" => "hostname", "stale_s" => 90 }.freeze

  def esp32_rule! = Setting.values["presence_rules"] = JSON.generate([ESP32_RULE])

  def test_rules_default_empty
    assert_equal [], Presence.rules
  end

  def test_rules_normalised
    esp32_rule!
    assert_equal [{ name: "esp32", pattern: "esp32/+/status", id_segment: 1, online_path: "online",
                    label_path: "hostname", stale_s: 90 }], Presence.rules
  end

  def test_rules_skip_invalid
    Setting.values["presence_rules"] = JSON.generate([
      { "name" => "bad", "pattern" => "a/#/b", "id_segment" => 1, "stale_s" => 10 },
      { "name" => "noint", "pattern" => "x/+", "id_segment" => "one", "stale_s" => 10 },
      "junk",
      { "name" => "ok", "pattern" => "dev/+/state", "id_segment" => "1", "stale_s" => "30" }
    ])
    assert_equal ["ok"], Presence.rules.map { |r| r[:name] }
    assert_equal 1, Presence.rules.first[:id_segment]
  end

  def test_rules_non_array
    Setting.values["presence_rules"] = '{"a":1}'
    assert_equal [], Presence.rules
  end

  def test_devices_online_offline_stale
    esp32_rule!
    TopicRegistry.entries = [
      entry("esp32/b/status", '{"online":true,"hostname":"Beta","rssi":-60}', NOW - 1_000),
      entry("esp32/a/status", '{"online":false}', NOW - 1_000),
      entry("esp32/c/status", '{"online":true,"hostname":"gamma"}', NOW - 100_000),
      entry("other/topic", '{"online":true}', NOW),
      entry("esp32/d/data", '{"online":true}', NOW)
    ]
    devices = at_now { Presence.devices }
    assert_equal %w[a b c], devices.map { |d| d[:id] }

    a, b, c = devices
    assert_equal [false, false, "a"], [a[:online], a[:stale], a[:label]]
    assert_equal [true, false, "Beta"], [b[:online], b[:stale], b[:label]]
    assert_equal({ "online" => true, "hostname" => "Beta", "rssi" => -60 }, b[:fields])
    assert_equal [false, true], [c[:online], c[:stale]]
    assert_equal NOW - 100_000 + 90_000, c[:since_ms]
    assert_equal "esp32", b[:name]
    assert_equal "esp32/b/status", b[:topic]
  end

  def test_devices_garbage_payload
    esp32_rule!
    TopicRegistry.entries = [entry("esp32/x/status", "\xFF\x00".b, NOW), entry("esp32/y/status", "{bad", NOW)]
    devices = at_now { Presence.devices }
    assert_equal [false, false], devices.map { |d| d[:online] }
    assert_equal [{}, {}], devices.map { |d| d[:fields] }
  end

  def test_plain_text_lwt
    Setting.values["presence_rules"] = JSON.generate([{ "name" => "lwt", "pattern" => "tele/+/LWT", "id_segment" => 1,
                                                        "online_path" => "online", "stale_s" => 1_000_000 }])
    TopicRegistry.entries = [entry("tele/p1/LWT", "Online", NOW), entry("tele/p2/LWT", "Offline", NOW)]
    devices = at_now { Presence.devices }
    assert_equal [true, false], devices.map { |d| d[:online] }
  end

  def test_since_scans_history_until_flip
    esp32_rule!
    topic = "esp32/a/status"
    TopicRegistry.entries = [entry(topic, '{"online":true}', NOW - 1_000)]
    Store.rows[topic] = [msg(NOW - 1_000, '{"online":true}'), msg(NOW - 31_000, '{"online":true}'),
                         msg(NOW - 61_000, '{"online":false}'), msg(NOW - 91_000, '{"online":true}')]
    Setting.values["history_default_limit"] = 50
    device = at_now { Presence.devices }.first
    assert_equal NOW - 31_000, device[:since_ms]
    assert_equal [{ topic: topic, from_ms: nil, to_ms: nil, limit: 50 }], Store.calls
  end

  def test_since_falls_back_to_last_seen
    esp32_rule!
    TopicRegistry.entries = [entry("esp32/a/status", '{"online":true}', NOW - 5)]
    assert_equal NOW - 5, at_now { Presence.devices }.first[:since_ms]
  end

  def test_label_path_nested
    Setting.values["presence_rules"] = JSON.generate([{ "name" => "n", "pattern" => "n/+", "id_segment" => 1,
                                                        "online_path" => "st.up", "label_path" => "info.names[1]",
                                                        "stale_s" => 60 }])
    TopicRegistry.entries = [entry("n/q", '{"st":{"up":1},"info":{"names":["x","Kitchen"]}}', NOW)]
    device = at_now { Presence.devices }.first
    assert_equal ["Kitchen", true], [device[:label], device[:online]]
  end

  def test_timeline_collapses_and_inserts_stale_gaps
    esp32_rule!
    topic = "esp32/a/status"
    TopicRegistry.entries = [entry(topic, '{"online":true}', NOW - 1_000)]
    t0 = NOW - 1_000_000
    Store.rows[topic] = [
      msg(t0, '{"online":true}'), msg(t0 + 30_000, '{"online":true}'),
      msg(t0 + 60_000, '{"online":false}'), msg(t0 + 70_000, '{"online":false}'),
      msg(t0 + 100_000, '{"online":true}'),
      msg(t0 + 400_000, '{"online":true}'),
      msg(NOW - 1_000, '{"online":true}')
    ]
    Setting.values["timeline_max_rows"] = 99
    timeline = at_now { Presence.timeline(id: "a", from_ms: t0, to_ms: nil) }
    assert_equal [
      { from_ms: t0, to_ms: t0 + 60_000, online: true },
      { from_ms: t0 + 60_000, to_ms: t0 + 100_000, online: false },
      { from_ms: t0 + 100_000, to_ms: t0 + 190_000, online: true },
      { from_ms: t0 + 190_000, to_ms: t0 + 400_000, online: false },
      { from_ms: t0 + 400_000, to_ms: t0 + 490_000, online: true },
      { from_ms: t0 + 490_000, to_ms: NOW - 1_000, online: false },
      { from_ms: NOW - 1_000, to_ms: nil, online: true }
    ], timeline
    assert_equal 99, Store.calls.last[:limit]
  end

  def test_timeline_goes_offline_when_silent_at_end
    esp32_rule!
    topic = "esp32/a/status"
    TopicRegistry.entries = [entry(topic, '{"online":true}', NOW - 500_000)]
    Store.rows[topic] = [msg(NOW - 500_000, '{"online":true}')]
    timeline = at_now { Presence.timeline(id: "a", from_ms: nil, to_ms: nil) }
    assert_equal [{ from_ms: NOW - 500_000, to_ms: NOW - 410_000, online: true },
                  { from_ms: NOW - 410_000, to_ms: nil, online: false }], timeline
  end

  def test_timeline_unknown_device
    esp32_rule!
    assert_equal [], Presence.timeline(id: "nope", from_ms: nil, to_ms: nil)
  end
end
