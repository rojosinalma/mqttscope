# frozen_string_literal: true

# STUB — owner A replaces this file. Contract: CONTRACTS.md → Ingest.
module Ingest
  class NotConnected < StandardError; end

  class << self
    def start
      $log.warn "[mqtt] Ingest stub — no broker connection yet"
    end

    def reconnect! = nil

    def status
      { connected: false, since_ms: nil, error: "stub", host: Setting.fetch("mqtt_host", "mosquitto"),
        port: Setting.fetch("mqtt_port", 1883), msgs_total: 0, msgs_per_s: 0.0, bytes_per_s: 0.0,
        topics: TopicRegistry.size, last_message_ms: nil }
    end

    def publish(topic:, payload:, retain: false, qos: 0)
      raise NotConnected, "stub"
    end
  end
end
