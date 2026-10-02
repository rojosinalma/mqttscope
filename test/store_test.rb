# frozen_string_literal: true

db_path = ENV.fetch("DATABASE_PATH") { abort "set DATABASE_PATH to a throwaway file" }
abort "refusing to test against #{db_path}" if db_path.include?("/data/")
Dir["#{db_path}*"].each { |f| File.delete(f) }

require "json"
require "minitest/autorun"
require_relative "../lib/logger"
$log.level = Logger::WARN
require_relative "../models/database"
require_relative "../models/setting"
require_relative "../models/topic"
require_relative "../models/message"
require_relative "../lib/worker_pool"
require_relative "../lib/topic_match"
require_relative "../lib/sampling"
require_relative "../lib/store"
require_relative "../lib/pruner"

class StoreTest < Minitest::Test
  NOW = (Time.now.to_f * 1000).to_i

  def setup
    DB[:messages].delete
    DB[:topics].delete
    DB[:settings].delete
    Setting.seed_defaults!
    Store.forget_topics!
  end

  def rec(topic, payload, ts, **opts)
    Store.record(topic: topic, payload: payload, ts_ms: ts, retained: false, qos: 0, origin: "broker", **opts)
  end

  def test_record_and_history_pagination
    ids = (1..5).map { |i| rec("a/b", %({"n":#{i}}), NOW + i)[:id] }
    rec("a/c", "other", NOW)

    page = Store.history(topic: "a/b", limit: 2)
    assert_equal ids.last(2).reverse, page.map { _1[:id] }
    assert_equal "a/b", page.first[:topic]
    assert_equal %({"n":5}), page.first[:payload]
    assert_equal false, page.first[:retained]

    page2 = Store.history(topic: "a/b", limit: 2, before_id: page.last[:id])
    assert_equal ids[1..2].reverse, page2.map { _1[:id] }

    ranged = Store.history(topic: "a/b", limit: 10, from_ms: NOW + 2, to_ms: NOW + 3)
    assert_equal ids[1..2].reverse, ranged.map { _1[:id] }

    assert_empty Store.history(topic: "nope", limit: 10)
    topic = DB[:topics].where(name: "a/b").first
    assert_equal 5, topic[:stored_count]
    assert_equal NOW + 5, topic[:last_seen_ms]
    assert_equal NOW + 1, topic[:first_seen_ms]
  end

  def test_message_previous_and_truncation
    Setting.set("max_payload_bytes", 10)
    first = rec("t", "short", NOW)
    second = rec("t", "x" * 50, NOW + 1)
    assert_equal false, first[:truncated]
    assert_equal true, second[:truncated]

    msg = Store.message(second[:id])
    assert_equal "x" * 10, msg[:payload]
    assert_equal 50, msg[:size]
    assert_equal true, msg[:truncated]
    assert_equal "t", msg[:topic]
    assert_equal first[:id], Store.previous(topic: "t", before_id: second[:id])[:id]
    assert_nil Store.previous(topic: "t", before_id: first[:id])
    assert_nil Store.message(-1)
  end

  def test_bump_dup
    rec("d", "same", NOW)
    latest = rec("d", "same2", NOW + 1)[:id]
    2.times { |i| Store.bump_dup(topic: "d", ts_ms: NOW + 10 + i) }
    assert_equal 3, DB[:messages].where(id: latest).get(:dup_count)
    assert_equal NOW + 11, DB[:topics].where(name: "d").get(:last_seen_ms)
    assert_nil Store.bump_dup(topic: "unknown", ts_ms: NOW)
  end

  def test_search_hit_miss_prefix_and_filter
    rec("home/kitchen/temp", %({"room":"kitchen","temp":21.5}), NOW)
    rec("home/garage/temp", %({"room":"garage","temp":12}), NOW + 1)
    rec("$SYS/broker/version", "mosquitto version 2.0", NOW + 2)

    hits = Store.search(q: "kitchen", limit: 10)
    assert_equal ["home/kitchen/temp"], hits.map { _1[:topic] }
    assert_includes hits.first[:snippet], "«kitchen»"
    assert_equal %i[id topic ts_ms size snippet].sort, hits.first.keys.sort

    assert_empty Store.search(q: "bathroom", limit: 10)
    assert_empty Store.search(q: "gar* kit*", limit: 10)
    assert_equal ["home/garage/temp"], Store.search(q: "gar*", limit: 10).map { _1[:topic] }
    assert_equal 2, Store.search(q: "room", limit: 10).size
    assert_equal ["home/garage/temp"], Store.search(q: "room", topic_filter: "home/garage/+", limit: 10).map { _1[:topic] }
    assert_equal ["home/kitchen/temp"], Store.search(q: "room", topic_filter: "home/kitchen/temp", limit: 10).map { _1[:topic] }
    assert_equal 1, Store.search(q: "room", limit: 1).size
    assert_empty Store.search(q: "mosquitto", topic_filter: "#", limit: 10)
    assert_equal 1, Store.search(q: "mosquitto", topic_filter: "$SYS/#", limit: 10).size
    assert_equal ["home/garage/temp"], Store.search(q: "room", from_ms: NOW + 1, limit: 10).map { _1[:topic] }
    assert_empty Store.search(q: '"unbalanced AND (', limit: 10)
    assert_equal ["home/kitchen/temp"], Store.search(q: 'room ( kitchen"', limit: 10).map { _1[:topic] }
    assert_empty Store.search(q: "   ", limit: 10)
  end

  def test_search_like_fallback
    rec("x/y", "Hello fallback world", NOW)
    Store.singleton_class.alias_method(:real_fts?, :fts?)
    Store.define_singleton_method(:fts?) { false }
    hits = Store.search(q: "FALLBACK", limit: 10)
    assert_equal ["x/y"], hits.map { _1[:topic] }
    assert_includes hits.first[:snippet], "fallback"
    assert_empty Store.search(q: "nothing", limit: 10)
  ensure
    Store.singleton_class.alias_method(:fts?, :real_fts?)
  end

  def test_series_bucketing
    100.times { |i| rec("s", JSON.generate(bands: { low: i }, arr: [i * 2], ok: "x"), NOW + i * 1000) }
    rec("s", "not json", NOW + 200_000)
    rec("n", "12.5", NOW)

    raw = Store.series(topic: "s", path: "bands.low", from_ms: NOW, to_ms: NOW + 1_000_000, max_points: 500)
    assert_equal 100, raw.size
    assert_equal [NOW, 0], raw.first

    buckets = Store.series(topic: "s", path: "bands.low", from_ms: NOW, to_ms: NOW + 1_000_000, max_points: 10)
    assert_equal 10, buckets.size
    assert_in_delta 4.5, buckets.first[1]
    assert buckets.each_cons(2).all? { |a, b| a[0] < b[0] }

    assert_equal 2, Store.series(topic: "s", path: "arr[0]", from_ms: NOW + 1000, to_ms: NOW + 1000, max_points: 5).first[1]
    assert_empty Store.series(topic: "s", path: "ok", from_ms: NOW, to_ms: NOW + 1_000_000, max_points: 5)
    assert_equal [[NOW, 12.5]], Store.series(topic: "n", path: "", from_ms: NOW, to_ms: NOW, max_points: 5)

    Setting.set("series_max_rows", 10)
    assert_equal NOW + 91_000, Store.series(topic: "s", path: "bands.low", from_ms: NOW, to_ms: NOW + 1_000_000, max_points: 500).first[0]
  end

  def test_sys_latest_and_stats
    rec("$SYS/broker/uptime", "10 seconds", NOW)
    rec("$SYS/broker/uptime", "20 seconds", NOW + 1)
    rec("$SYS/broker/clients/connected", "3", NOW)
    rec("other", "x", NOW)
    assert_equal({ "$SYS/broker/uptime" => "20 seconds", "$SYS/broker/clients/connected" => "3" }, Store.sys_latest)

    stats = Store.stats
    assert_equal 4, stats[:messages]
    assert_equal 3, stats[:topics]
    assert_equal NOW, stats[:oldest_ms]
    assert_equal "none", stats[:governing]
    assert_operator stats[:size_bytes], :>, 0

    rec("old", "x", NOW - 8 * 86_400_000)
    assert_equal "retention", Store.stats[:governing]
    Setting.set("max_db_bytes", 1)
    assert_equal "size", Store.stats[:governing]
  end

  def test_prune_by_age
    old = NOW - 8 * 86_400_000
    5.times { |i| rec("gone", "old #{i}", old + i) }
    3.times { |i| rec("mixed", "old #{i}", old + i) }
    rec("mixed", "fresh", NOW)
    Setting.set("prune_batch", 2)

    result = Pruner.run_now
    assert_equal 8, result[:deleted_by_age]
    assert_equal 0, result[:deleted_by_size]
    assert_equal 1, result[:topics_dropped]
    assert_equal 1, DB[:messages].count
    assert_equal ["mixed"], DB[:topics].select_map(:name)
    assert_equal 1, DB[:topics].where(name: "mixed").get(:stored_count)
    assert_equal NOW, DB[:messages].get(:ts_ms)
    assert Pruner.last_run[:at_ms]
    assert_equal 0, DB.fetch("PRAGMA freelist_count").single_value

    rec("gone", "back again", NOW)
    assert_equal 1, DB[:topics].where(name: "gone").get(:stored_count)
  end

  def test_prune_by_size
    assert_equal 2, DB.fetch("PRAGMA auto_vacuum").single_value
    Setting.set("max_payload_bytes", 1_000_000)
    rng = Random.new(1)
    400.times { |i| rec("big/#{i % 4}", rng.bytes(5_000).unpack1("H*"), NOW + i) }
    DB.run("PRAGMA wal_checkpoint(TRUNCATE)")
    before = Store.db_size_bytes
    assert_operator before, :>, 4_000_000

    max_bytes = 3_000_000
    Setting.set("max_db_bytes", max_bytes)
    Setting.set("prune_batch", 50)
    result = Pruner.run_now
    assert_operator result[:deleted_by_size], :>, 0
    assert_operator result[:size_after], :<=, max_bytes
    assert_operator Store.used_bytes, :<=, max_bytes
    assert_equal NOW + 399, DB[:messages].max(:ts_ms)
    assert_equal DB[:messages].count, DB[:topics].sum(:stored_count)
    DB.run("INSERT INTO messages_fts(messages_fts) VALUES ('integrity-check')")
  end

  def test_run_now_coalesces
    Pruner.instance_variable_get(:@run_lock).lock
    assert_equal({ skipped: true }, Pruner.run_now)
  ensure
    Pruner.instance_variable_get(:@run_lock).unlock
  end

  def test_record_speed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    500.times { |i| rec("speed/#{i % 20}", %({"v":#{i}}), NOW + i) }
    per_call_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000 / 500
    puts format("\n  Store.record: %.2f ms/call", per_call_ms)
    assert_operator per_call_ms, :<, 10
  end
end
