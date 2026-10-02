# frozen_string_literal: true

ENV["DATABASE_PATH"] ||= "/tmp/api-test.db"
db_path = ENV["DATABASE_PATH"]
Dir["#{db_path}*"].each { |f| File.delete(f) } if db_path.start_with?("/tmp/")

require "minitest/autorun"
require "rack/mock"
require "json"
require_relative "../app"

Setting.seed_defaults!

class ApiTest < Minitest::Test
  def setup
    @app = Rack::MockRequest.new(App.app)
    @saved = Setting.all_values
  end

  def teardown
    @saved.each { |key, value| Setting.set(key, value) }
  end

  def get(path) = parse(@app.get(path))

  def post(path, body)
    parse(@app.post(path, input: JSON.generate(body), "CONTENT_TYPE" => "application/json"))
  end

  def parse(res) = [res.status, JSON.parse(res.body)]

  # Replaces a singleton method for the duration of the block (minitest 6 ships no #stub).
  def with_singleton(mod, name, impl)
    original = mod.method(name)
    mod.define_singleton_method(name, &impl)
    yield
  ensure
    mod.define_singleton_method(name, original)
  end

  def test_topics
    status, body = get("/api/topics")
    assert_equal 200, status
    assert body["ok"]
    assert_kind_of Array, body["topics"]
  end

  def test_messages_requires_topic
    status, body = get("/api/messages")
    assert_equal 400, status
    refute body["ok"]
    assert_match(/topic is required/, body["message"])
  end

  def test_messages_with_topic
    status, body = get("/api/messages?topic=a/b&limit=5")
    assert_equal 200, status
    assert_equal [], body["messages"]
  end

  def test_messages_rejects_bad_limit
    assert_equal 400, get("/api/messages?topic=a&limit=0").first
    assert_equal 400, get("/api/messages?topic=a&limit=abc").first
  end

  def test_message_not_found
    assert_equal 404, get("/api/messages/999999").first
  end

  def test_search_rejects_bad_filter
    assert_equal 400, get("/api/search?q=x&topic=a/%23/b").first
    assert_equal 400, get("/api/search").first
  end

  def test_settings_masks_password
    Setting.set("mqtt_pass", "hunter2")
    status, body = get("/api/settings")
    assert_equal 200, status
    assert_equal "••••", body["settings"]["mqtt_pass"]
    refute_includes JSON.generate(body), "hunter2"
  end

  def test_settings_mask_leaves_password_alone
    Setting.set("mqtt_pass", "hunter2")
    with_singleton(Ingest, :reconnect!, -> { nil }) do
      status, body = post("/api/settings", { "mqtt_pass" => "••••", "retention_days" => 5 })
      assert_equal 200, status, body.inspect
      assert_equal ["retention_days"], body["changed"]
      refute body["reconnecting"]
    end
    assert_equal "hunter2", Setting.fetch("mqtt_pass", "")
    assert_equal 5, Setting.fetch("retention_days", 7)
  end

  def test_settings_rejects_bad_values_and_unknown_keys
    cases = [
      { "retention_days" => 0 },
      { "mqtt_port" => "abc" },
      { "publish_enabled" => "maybe" },
      { "mqtt_subscriptions" => "a/#/b" },
      { "sample_rules" => "not json" },
      { "sample_rules" => [{ "pattern" => "a/#", "min_interval_ms" => -1 }] },
      { "presence_rules" => [{ "pattern" => "x/+" }] },
      { "sse_heartbeat_s" => 600, "sse_idle_timeout_s" => 60 },
      { "nonsense" => 1 },
      {}
    ]
    cases.each do |body|
      status, res = post("/api/settings", body)
      assert_equal 400, status, "expected 400 for #{body.inspect}, got #{res.inspect}"
      refute res["ok"]
    end
    assert_equal 7, Setting.fetch("retention_days", 7)
  end

  def test_settings_normalises_and_reconnects_on_connection_change
    reconnects = 0
    with_singleton(Ingest, :reconnect!, -> { reconnects += 1 }) do
      status, body = post("/api/settings", {
        "mqtt_subscriptions" => ["#", " $SYS/broker/# "], "dedup_enabled" => false,
        "sample_rules" => [{ "pattern" => "esp32/+/data", "min_interval_ms" => 5000 }]
      })
      assert_equal 200, status, body.inspect
      assert body["reconnecting"]
    end
    assert_equal 1, reconnects
    assert_equal "#,$SYS/broker/#", Setting.all_values["mqtt_subscriptions"]
    assert_equal "false", Setting.all_values["dedup_enabled"]
    assert_equal 5000, JSON.parse(Setting.all_values["sample_rules"]).first["min_interval_ms"]
  end

  def test_publish_forbidden_when_disabled
    Setting.set("publish_enabled", "false")
    status, body = post("/api/publish", { "topic" => "test/x", "payload" => "hi" })
    assert_equal 403, status
    refute body["ok"]
  end

  def test_publish_not_connected
    Setting.set("publish_enabled", "true")
    with_singleton(Ingest, :publish, ->(**) { raise Ingest::NotConnected, "down" }) do
      status, body = post("/api/publish", { "topic" => "test/x", "payload" => "hi" })
      assert_equal 503, status
      assert_match(/not connected/i, body["message"])
    end
  end

  def test_publish_validates_and_publishes
    Setting.set("publish_enabled", "true")
    seen = nil
    with_singleton(Ingest, :publish, ->(**kw) { seen = kw }) do
      assert_equal 400, post("/api/publish", { "topic" => "a/+", "payload" => "x" }).first
      assert_equal 400, post("/api/publish", { "topic" => "a", "qos" => 3 }).first
      status, body = post("/api/publish", { "topic" => "a/b", "payload" => { "n" => 1 }, "retain" => true, "qos" => 1 })
      assert_equal 200, status, body.inspect
    end
    assert_equal({ topic: "a/b", payload: '{"n":1}', retain: true, qos: 1 }, seen)
  end

  def test_stats
    status, body = get("/api/stats")
    assert_equal 200, status
    assert body.key?("ingest")
    assert body.key?("sse_clients")
  end

  def test_stream_rejects_bad_filter
    assert_equal 400, get("/api/stream?topics=a/%23/b").first
  end

  def test_stream_too_many_clients
    Setting.set("sse_max_clients", "0")
    status, body = get("/api/stream")
    assert_equal 503, status
    assert_equal "Too many live streams", body["message"]
  end

  def test_stream_hello_ping_bye_and_unsubscribes
    Setting.set("sse_heartbeat_s", "1")
    Setting.set("sse_idle_timeout_s", "2")
    res = @app.get("/api/stream?topics=t/%2B")
    assert_equal 200, res.status
    assert_equal "text/event-stream", res.headers["content-type"]
    assert_match(/\Aevent: hello\ndata: \{"filters":\["t\/\+"\]/, res.body)
    assert_includes res.body, ": ping\n\n"
    assert res.body.end_with?("event: bye\ndata: {\"reason\":\"idle\"}\n\n"), res.body
    assert_equal 0, Bus.client_count
  end

  def test_pump_emits_events_and_dropped
    sub = Bus.subscribe(filters: ["t/#"], max_queue: 2, max_clients: 5)
    3.times { |i| Bus.publish(type: "message", topic: "t/#{i}", payload: i.to_s) }
    Bus.publish(type: "message", topic: "other", payload: "x")
    out = []
    SseStream.pump(out, sub, heartbeat_s: 0.1, idle_timeout_s: 0.3)
    text = out.join
    assert_includes text, "event: dropped\ndata: {\"type\":\"dropped\",\"n\":1}\n\n"
    assert_includes text, "\"topic\":\"t/2\""
    refute_includes text, "\"topic\":\"t/0\""
    refute_includes text, "\"topic\":\"other\""
    assert text.end_with?("event: bye\ndata: {\"reason\":\"idle\"}\n\n")
  ensure
    Bus.unsubscribe(sub) if sub
  end

  def test_pump_stops_on_client_gone
    sub = Bus.subscribe(filters: ["#"], max_queue: 10, max_clients: 5)
    gone = Object.new
    def gone.<<(_chunk) = raise(Errno::EPIPE)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    SseStream.pump(gone, sub, heartbeat_s: 5, idle_timeout_s: 10)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1
  ensure
    Bus.unsubscribe(sub) if sub
  end
end
