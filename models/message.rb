# frozen_string_literal: true

require "base64"

class Message < Sequel::Model(:messages)
  many_to_one :topic

  def to_api(topic_name: nil)
    text = payload.to_s.dup.force_encoding(Encoding::UTF_8)
    binary = !text.valid_encoding?
    {
      id: id, topic: topic_name || topic&.name, ts_ms: ts_ms,
      payload: binary ? nil : text, binary: binary, payload_b64: (Base64.strict_encode64(payload.to_s) if binary),
      size: size, retained: retained, qos: qos, origin: origin, dup_count: dup_count, truncated: truncated
    }
  end
end
