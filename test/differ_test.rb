# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/differ"

class DifferTest < Minitest::Test
  def test_classify
    assert_equal :empty, Differ.classify(nil)
    assert_equal :empty, Differ.classify("")
    assert_equal :json, Differ.classify('{"a":1}')
    assert_equal :json, Differ.classify(" [1,2]")
    assert_equal :json, Differ.classify("123")
    assert_equal :json, Differ.classify("-4.5")
    assert_equal :json, Differ.classify("true")
    assert_equal :text, Differ.classify("online")
    assert_equal :text, Differ.classify("nope")
    assert_equal :text, Differ.classify("{broken")
    assert_equal :binary, Differ.classify("\xFF\xFE\x00".b)
  end

  def test_same
    assert_equal({ kind: "same", summary: "no change", changes: [] }, Differ.diff('{"a":1}', '{"a":1}'))
    assert_equal "same", Differ.diff(nil, "")[:kind]
  end

  def test_json_semantic_same_with_different_formatting
    assert_equal "same", Differ.diff('{"a":1,"b":2}', '{ "b": 2, "a": 1 }')[:kind]
  end

  def test_json_nested_changes
    old = '{"bands":{"low":1,"high":2},"samples":[1,2,3],"gone":"x"}'
    new = '{"bands":{"low":1.5,"high":2},"samples":[1,9,3,4],"new":true}'
    d = Differ.diff(old, new)
    assert_equal "json", d[:kind]
    assert_includes d[:changes], { path: "bands.low", op: "changed", from: 1, to: 1.5 }
    assert_includes d[:changes], { path: "samples[1]", op: "changed", from: 2, to: 9 }
    assert_includes d[:changes], { path: "samples[3]", op: "added", from: nil, to: 4 }
    assert_includes d[:changes], { path: "gone", op: "removed", from: "x", to: nil }
    assert_includes d[:changes], { path: "new", op: "added", from: nil, to: true }
    assert_equal "2 changed, 2 added, 1 removed", d[:summary]
  end

  def test_json_array_shrink_and_type_change
    d = Differ.diff('{"a":[1,2,3],"t":{"x":1}}', '{"a":[1],"t":5}')
    assert_includes d[:changes], { path: "a[1]", op: "removed", from: 2, to: nil }
    assert_includes d[:changes], { path: "a[2]", op: "removed", from: 3, to: nil }
    assert_includes d[:changes], { path: "t", op: "changed", from: { "x" => 1 }, to: 5 }
  end

  def test_first_message_all_leaves_added
    d = Differ.diff(nil, '{"a":{"b":1},"c":[true,"x"]}')
    assert_equal "json", d[:kind]
    assert_equal %w[a.b c[0] c[1]], d[:changes].map { |c| c[:path] }
    assert(d[:changes].all? { |c| c[:op] == "added" })
    assert_equal "3 added", d[:summary]
  end

  def test_scalar_json
    d = Differ.diff("1", "2")
    assert_equal [{ path: "", op: "changed", from: 1, to: 2 }], d[:changes]
  end

  def test_raw_numbers_kept
    d = Differ.diff('{"v":1}', '{"v":1.0}')
    assert_equal [{ path: "v", op: "changed", from: 1, to: 1.0 }], d[:changes]
  end

  def test_text_line_diff
    d = Differ.diff("a\nb\nc\nd", "a\nB\nc\nd\ne")
    assert_equal "text", d[:kind]
    assert_equal [{ line: 2, op: "changed", from: "b", to: "B" }, { line: 5, op: "added", from: nil, to: "e" }],
                 d[:changes]
    assert_equal "1 changed, 1 added", d[:summary]
  end

  def test_text_removed_line
    d = Differ.diff("a\nb\nc", "a\nc")
    assert_equal [{ line: 2, op: "removed", from: "b", to: nil }], d[:changes]
  end

  def test_text_vs_json_falls_back_to_lines
    d = Differ.diff("offline", '{"online":true}')
    assert_equal "text", d[:kind]
    assert_equal [{ line: 1, op: "changed", from: "offline", to: '{"online":true}' }], d[:changes]
  end

  def test_text_first_message
    d = Differ.diff(nil, "hello\nworld")
    assert_equal "2 added", d[:summary]
  end

  def test_text_too_large_reports_summary
    old = (1..2500).map { |i| "line #{i}" }.join("\n")
    new = (1..2500).map { |i| "LINE #{i}" }.join("\n")
    d = Differ.diff(old, new)
    assert_equal "text", d[:kind]
    assert_empty d[:changes]
    assert_match(/too large/, d[:summary])
  end

  def test_large_common_prefix_is_still_diffed
    base = (1..5000).map { |i| "line #{i}" }
    d = Differ.diff(base.join("\n"), (base + ["tail"]).join("\n"))
    assert_equal [{ line: 5001, op: "added", from: nil, to: "tail" }], d[:changes]
  end

  def test_binary
    d = Differ.diff("\xFF\x00".b, "\xFF\x00\x01".b)
    assert_equal "binary", d[:kind]
    assert_equal "binary, 2 → 3 bytes (+1)", d[:summary]
    assert_equal "binary, 3 bytes", Differ.diff(nil, "\xFF\x00\x01".b)[:summary]
  end

  def test_flatten
    assert_equal({ "a.b" => 1, "arr[0]" => "x", "arr[1].k" => nil, "e" => {}, "l" => [] },
                 Differ.flatten({ "a" => { "b" => 1 }, "arr" => ["x", { "k" => nil }], "e" => {}, "l" => [] }))
  end

  def test_numeric_paths
    payload = '{"z":1,"a":{"f":2.5,"s":"x","b":true},"arr":[3,null]}'
    assert_equal %w[a.f arr[0] z], Differ.numeric_paths(payload)
    assert_equal [], Differ.numeric_paths("hello")
    assert_equal [], Differ.numeric_paths(nil)
  end
end
