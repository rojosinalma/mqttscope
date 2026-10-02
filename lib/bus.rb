# frozen_string_literal: true

require_relative "topic_match"

# In-process fan-out from Ingest to SSE clients. Bounded in both directions:
# a cap on subscribers and a SizedQueue per subscriber (overflow drops the oldest).
module Bus
  Subscriber = Struct.new(:filters, :queue, :dropped, :created_at) do
    def push(event)
      queue.push(event, true)
    rescue ThreadError
      begin
        queue.pop(true)
      rescue ThreadError
        nil
      end
      self.dropped += 1
      begin
        queue.push(event, true)
      rescue ThreadError
        nil
      end
    end
  end

  @lock = Mutex.new
  @subs = []

  class << self
    def subscribe(filters: ["#"], max_queue: 500, max_clients: 20)
      sub = Subscriber.new(Array(filters), SizedQueue.new(max_queue), 0, Time.now)
      @lock.synchronize do
        return nil if @subs.size >= max_clients

        @subs << sub
      end
      $log.info "[sse] client subscribed filters=#{sub.filters.join(',')} clients=#{client_count}"
      sub
    end

    def unsubscribe(sub)
      @lock.synchronize { @subs.delete(sub) }
      $log.info "[sse] client gone clients=#{client_count}"
    end

    def publish(event)
      topic = event[:topic]
      targets = @lock.synchronize { @subs.dup }
      targets.each do |sub|
        next if topic && !TopicMatch.match_any?(sub.filters, topic)

        sub.push(event)
      end
    end

    def client_count = @lock.synchronize { @subs.size }
  end
end
