# frozen_string_literal: true

require "mqtt"
require "digest"

# The one broker connection: a supervised reader thread that feeds every received packet
# through TopicRegistry → Sampling → Store → Bus, plus a ticker that emits stats events.
module Ingest
  class NotConnected < StandardError; end
  class Reconnect < StandardError; end

  SUBSCRIBE_QOS = 1
  PUBLISH_QOS = [0, 1].freeze
  ECHO_MAX = 1000
  HOT_SETTINGS_TTL_MS = 1000
  CONNECTION_ERRORS = [StandardError, MQTT::Exception].freeze

  @lock = Mutex.new
  @publish_lock = Mutex.new
  @thread = nil
  @ticker = nil
  @client = nil
  @reconnect_pending = false
  @state = { connected: false, since_ms: nil, error: nil, host: nil, port: nil }
  @msgs_total = 0
  @last_message_ms = nil
  @ring = nil
  @echoes = {}
  @hot = {}
  @hot_at = 0
  @last_error = { key: nil, at_ms: 0, suppressed: 0 }

  class << self
    def start
      @lock.synchronize do
        @thread = WorkerPool.safe_thread("mqtt-ingest") { supervise } unless @thread&.alive?
        @ticker = WorkerPool.safe_thread("mqtt-stats") { tick_stats } unless @ticker&.alive?
      end
      nil
    end

    def reconnect!
      thread = @thread
      return start unless thread&.alive?

      @lock.synchronize do
        return nil if @reconnect_pending

        @reconnect_pending = true
      end
      $log.info "[mqtt] reconnect requested"
      thread.raise(Reconnect, "reconnect requested")
      nil
    end

    def status
      rates = @lock.synchronize { @ring ? @ring.rates(Time.now.to_i) : [0.0, 0.0] }
      state = @lock.synchronize { @state.dup }
      {
        connected: state[:connected], since_ms: state[:since_ms], error: state[:error],
        host: state[:host] || Setting.fetch("mqtt_host", "mosquitto"),
        port: state[:port] || Setting.fetch("mqtt_port", 1883),
        msgs_total: @msgs_total, msgs_per_s: rates[0].round(2), bytes_per_s: rates[1].round(1),
        topics: TopicRegistry.size, last_message_ms: @last_message_ms
      }
    end

    def publish(topic:, payload:, retain: false, qos: 0)
      payload = payload.to_s
      qos = Integer(qos, exception: false)
      raise ArgumentError, "Invalid topic #{topic.inspect}" unless TopicMatch.valid_topic?(topic)
      raise ArgumentError, "QoS must be one of #{PUBLISH_QOS.join(', ')}" unless PUBLISH_QOS.include?(qos)

      max = Setting.fetch("max_payload_bytes", 262_144)
      raise ArgumentError, "Payload is #{payload.bytesize} bytes, the limit is #{max}" if payload.bytesize > max

      client = @lock.synchronize { @client if @state[:connected] }
      raise NotConnected, "Not connected to the broker" unless client&.connected?

      remember_echo(topic, payload)
      result = @publish_lock.synchronize { client.publish(topic, payload, retain ? true : false, qos) }
      raise NotConnected, "Broker did not acknowledge the publish" if result == -1

      $log.info "[mqtt] publish topic=#{topic} bytes=#{payload.bytesize} retain=#{retain ? true : false} qos=#{qos}"
      nil
    rescue MQTT::NotConnectedException, IOError, SystemCallError => e
      $log.warn "[mqtt] publish failed topic=#{topic}: #{e.class}: #{e.message}"
      raise NotConnected, "Publish failed: #{e.message}"
    end

    private

    def now_ms = (Time.now.to_f * 1000).to_i

    # Async interrupts (reconnect!, and errors the mqtt gem's reader thread raises into us)
    # are only delivered inside `interruptible`, so packet processing is never cut in half.
    def supervise
      Thread.handle_interrupt(Object => :never) do
        attempt = 0
        loop do
          session { attempt = 0 }
        rescue Reconnect
          close_client
          @lock.synchronize { @reconnect_pending = false }
          mark_disconnected(nil)
          attempt = 0
        rescue *CONNECTION_ERRORS => e
          close_client
          mark_disconnected("#{e.class}: #{e.message}")
          delay = backoff(attempt)
          attempt += 1
          $log.warn "[mqtt] disconnected: #{e.class}: #{e.message}; retrying in #{delay}s"
          attempt = 0 if backoff_sleep(delay) == :reconnect
        end
      end
    end

    def session
      cfg = connection_settings
      @lock.synchronize { @state[:host] = cfg[:host]; @state[:port] = cfg[:port] }
      client = MQTT::Client.new(host: cfg[:host], port: cfg[:port], username: cfg[:username], password: cfg[:password],
                                client_id: cfg[:client_id], keep_alive: cfg[:keep_alive], clean_session: true)
      @lock.synchronize { @client = client }
      interruptible { client.connect }
      client.subscribe(cfg[:filters].to_h { |f| [f, SUBSCRIBE_QOS] })
      $log.info "[mqtt] connected #{cfg[:host]}:#{cfg[:port]} user=#{cfg[:username]} client_id=#{cfg[:client_id]} " \
                "subscriptions=#{cfg[:filters].join(',')}"
      mark_connected
      yield
      loop do
        drain_backlog(client)
        packet = interruptible { client.get_packet }
        handle(packet)
      end
    end

    def interruptible(&) = Thread.handle_interrupt(Object => :immediate, &)

    def connection_settings
      filters = Setting.list("mqtt_subscriptions", ["#"])
      invalid = filters.reject { |f| TopicMatch.valid_filter?(f) }
      $log.warn "[mqtt] ignoring invalid subscription filters: #{invalid.join(', ')}" unless invalid.empty?
      filters -= invalid
      raise ArgumentError, "mqtt_subscriptions has no valid filter" if filters.empty?

      pass = Setting.fetch("mqtt_pass", "")
      user = Setting.fetch("mqtt_user", "")
      {
        host: Setting.fetch("mqtt_host", "mosquitto"), port: Setting.fetch("mqtt_port", 1883),
        username: user.empty? ? nil : user, password: pass.empty? ? nil : pass,
        client_id: Setting.fetch("mqtt_client_id", "mqttscope"), keep_alive: Setting.fetch("mqtt_keepalive_s", 30),
        filters: filters
      }
    end

    def backoff(attempt)
      steps = Setting.list("reconnect_backoff_s", %w[2 5 10 30 60]).filter_map { |s| Float(s, exception: false) }
      steps = [1.0] if steps.empty?
      delay = steps[[attempt, steps.size - 1].min]
      delay == delay.to_i ? delay.to_i : delay
    rescue StandardError => e
      WorkerPool.log_error("mqtt-ingest backoff", e)
      1
    end

    # A stale error the old client's reader raised into us just before it was closed is
    # delivered here too; it only shortens the wait.
    def backoff_sleep(delay)
      interruptible { sleep delay }
      nil
    rescue Reconnect
      @lock.synchronize { @reconnect_pending = false }
      :reconnect
    rescue *CONNECTION_ERRORS
      nil
    end

    def close_client
      client = @lock.synchronize { @client.tap { @client = nil } }
      client&.disconnect(false)
    rescue *CONNECTION_ERRORS => e
      $log.debug "[mqtt] close: #{e.class}: #{e.message}"
    end

    def mark_connected = change_state(connected: true, error: nil)

    def mark_disconnected(error) = change_state(connected: false, error: error)

    def change_state(connected:, error:)
      ts = now_ms
      changed = @lock.synchronize do
        next false if @state[:connected] == connected && @state[:error] == error

        @state[:since_ms] = ts if @state[:connected] != connected || @state[:since_ms].nil?
        @state[:connected] = connected
        @state[:error] = error
        true
      end
      Bus.publish(type: "connection", connected: connected, error: error, ts_ms: ts) if changed
    end

    # The gem's read queue is unbounded; when processing falls behind, queued packets are
    # acknowledged and discarded instead of letting it grow.
    def drain_backlog(client)
      max = hot("ingest_max_backlog", 10_000)
      queued = client.queue_length
      return if queued <= max

      queued.times { client.get_packet }
      $log.warn "[mqtt] ingest fell behind: dropped #{queued} queued messages (ingest_max_backlog=#{max})"
    end

    def handle(packet)
      ts = now_ms
      topic = packet.topic
      topic = topic.scrub("\uFFFD") unless topic.valid_encoding?
      payload = packet.payload
      size = payload.bytesize
      retained = packet.retain ? true : false
      count_message(ts, size)

      Bus.publish(type: "topic", topic: topic, first_seen_ms: ts) if
        TopicRegistry.touch(topic: topic, ts_ms: ts, size: size, retained: retained, payload: payload) == true

      origin = consume_echo(topic, payload) ? "ui" : "broker"
      sampled = Sampling.store?(topic: topic, payload: payload, ts_ms: ts)
      stored = sampled || origin == "ui"
      result = nil
      if stored
        result = Store.record(topic: topic, payload: payload, ts_ms: ts, retained: retained, qos: packet.qos, origin: origin)
      elsif dedup_hit?(topic)
        Store.bump_dup(topic: topic, ts_ms: ts)
      end

      Bus.publish(message_event(topic:, payload:, ts:, retained:, qos: packet.qos, origin:, stored:, result:))
    rescue StandardError => e
      log_packet_error(e)
    end

    def dedup_hit?(topic)
      Sampling.respond_to?(:last_reason) && %w[dup dedup].include?(Sampling.last_reason(topic).to_s)
    end

    def message_event(topic:, payload:, ts:, retained:, qos:, origin:, stored:, result:)
      max = hot("max_payload_bytes", 262_144)
      truncated = payload.bytesize > max || (result.is_a?(Hash) && result[:truncated]) ? true : false
      kept = payload.bytesize > max ? payload.byteslice(0, max) : payload
      text = TopicRegistry.text_or_nil(kept, truncated: truncated)
      event = { type: "message", topic: topic, payload: text, ts_ms: ts, retained: retained, qos: qos,
                size: payload.bytesize, origin: origin, stored: stored,
                id: result.is_a?(Hash) ? result[:id] : nil, truncated: truncated }
      event.merge!(binary: true, payload_b64: [kept].pack("m0")) if text.nil?
      event
    end

    def count_message(ts, size)
      window = hot("rate_window_s", 60)
      @lock.synchronize do
        @ring = TopicRegistry::RateRing.new(window) if @ring.nil? || @ring.window != window
        @ring.add(ts / 1000, size)
        @msgs_total += 1
        @last_message_ms = ts
      end
    end

    def echo_key(topic, payload) = "#{topic}\0#{Digest::SHA256.hexdigest(payload)}"

    def remember_echo(topic, payload)
      ttl_ms = Setting.fetch("publish_echo_ttl_s", 10) * 1000
      key = echo_key(topic, payload)
      now = now_ms
      @lock.synchronize do
        @echoes.delete_if { |_, expires| expires < now }
        @echoes.delete(key)
        @echoes[key] = now + ttl_ms
        @echoes.shift while @echoes.size > ECHO_MAX
      end
    end

    def consume_echo(topic, payload)
      return false if @lock.synchronize { @echoes.empty? }

      key = echo_key(topic, payload)
      expires = @lock.synchronize { @echoes.delete(key) }
      !expires.nil? && expires >= now_ms
    end

    # Settings read once per packet are refreshed at most once a second.
    def hot(key, default)
      now = now_ms
      if now - @hot_at > HOT_SETTINGS_TTL_MS
        @hot = {}
        @hot_at = now
      end
      @hot.fetch(key) { @hot[key] = Setting.fetch(key, default) }
    end

    # A failing Store would otherwise log a backtrace per message; one per window is enough.
    def log_packet_error(error)
      key = "#{error.class}: #{error.message}"
      now = now_ms
      window_ms = hot("rate_window_s", 60) * 1000
      if key == @last_error[:key] && now - @last_error[:at_ms] < window_ms
        @last_error[:suppressed] += 1
        return
      end

      suppressed = @last_error[:suppressed]
      @last_error = { key: key, at_ms: now, suppressed: 0 }
      $log.warn "[mqtt] #{suppressed} similar packet errors suppressed" if suppressed.positive?
      WorkerPool.log_error("mqtt-ingest packet", error)
    end

    def tick_stats
      loop do
        sleep [Setting.fetch("rate_window_s", 60) / 6.0, 1].max
        Bus.publish(type: "stats", ingest: status, ts_ms: now_ms)
      rescue StandardError => e
        WorkerPool.log_error("mqtt-stats", e)
      end
    end
  end
end
