# frozen_string_literal: true

# MQTT topic filter matching (MQTT 3.1.1 §4.7): "+" matches one level, "#" the rest.
# Topics starting with "$" (e.g. $SYS) only match filters that also start with "$".
module TopicMatch
  module_function

  def match?(filter, topic)
    return false if filter.nil? || topic.nil?
    return false if topic.start_with?("$") && !filter.start_with?("$")

    f = filter.split("/", -1)
    t = topic.split("/", -1)
    f.each_with_index do |part, i|
      return true if part == "#"
      return false if i >= t.size
      return false unless part == "+" || part == t[i]
    end
    f.size == t.size
  end

  def match_any?(filters, topic) = Array(filters).any? { |f| match?(f, topic) }

  def valid_filter?(filter)
    return false if filter.nil? || filter.empty? || filter.bytesize > 65_535 || filter.include?("\0")

    parts = filter.split("/", -1)
    parts.each_with_index.all? do |part, i|
      next i == parts.size - 1 if part == "#"
      next true if part == "+"

      !part.include?("+") && !part.include?("#")
    end
  end

  def valid_topic?(topic)
    !topic.nil? && !topic.empty? && topic.bytesize <= 65_535 && !topic.include?("\0") &&
      !topic.include?("+") && !topic.include?("#")
  end
end
