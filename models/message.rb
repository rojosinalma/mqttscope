# frozen_string_literal: true

class Message < Sequel::Model(:messages)
  many_to_one :topic

  def to_api(topic_name: nil)
    text = payload.to_s.dup.force_encoding(Encoding::UTF_8)
    {
      id: id, topic: topic_name || topic&.name, ts_ms: ts_ms,
      payload: text.valid_encoding? ? text : nil, binary: !text.valid_encoding?,
      size: size, retained: retained, qos: qos, origin: origin, dup_count: dup_count, truncated: truncated
    }
  end
end
