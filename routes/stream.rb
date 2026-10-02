# frozen_string_literal: true

require "json"

# Server-sent events pump for GET /api/stream (routed in routes/api.rb). Writes each Bus
# event straight to the client as it is popped — nothing is buffered here.
module SseStream
  GONE_ERRORS = [IOError, SystemCallError].freeze

  module_function

  # An idempotent unsubscribe, safe to call from both the stream's ensure and its close callback.
  def releaser(sub)
    lock = Mutex.new
    released = false
    lambda do
      first = lock.synchronize { !released && (released = true) }
      ::Bus.unsubscribe(sub) if first
    end
  end

  def pump(out, sub, heartbeat_s:, idle_timeout_s:)
    out << frame("hello", { filters: sub.filters, ingest: ::Ingest.status })
    last_event_at = monotonic
    reported_drops = 0

    loop do
      drops = sub.dropped
      if drops > reported_drops
        out << frame("dropped", { type: "dropped", n: drops - reported_drops })
        reported_drops = drops
        last_event_at = monotonic
      end

      remaining = idle_timeout_s - (monotonic - last_event_at)
      return bye(out, idle_timeout_s) if remaining <= 0

      event = sub.queue.pop(timeout: [heartbeat_s, remaining].min)
      if event
        chunk = event_frame(event)
        out << chunk if chunk
        last_event_at = monotonic
      else
        out << ": ping\n\n"
      end
    end
  rescue *GONE_ERRORS => e
    $log.info "[sse] client went away (#{e.class})"
  rescue StandardError => e
    raise unless e.class.name == "Puma::ConnectionError"

    $log.info "[sse] client went away (#{e.class})"
  end

  def frame(type, data) = "event: #{type}\ndata: #{JSON.generate(data)}\n\n"

  def event_frame(event)
    frame(event[:type] || "message", event)
  rescue JSON::GeneratorError, Encoding::UndefinedConversionError => e
    $log.warn "[sse] skipping unencodable #{event[:type]} event on #{event[:topic].inspect}: #{e.message}"
    nil
  end

  def bye(out, idle_timeout_s)
    $log.info "[sse] closing stream idle for #{idle_timeout_s}s"
    out << frame("bye", { reason: "idle" })
  end

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
