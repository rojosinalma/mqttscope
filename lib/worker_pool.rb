# frozen_string_literal: true

module WorkerPool
  module_function

  def safe_thread(name, &block)
    Thread.new do
      block.call
    rescue Exception => e
      log_error(name, e)
    end.tap { |t| t.name = name }
  end

  def log_error(name, error)
    $log.error "[thread] #{name}: #{error.class}: #{error.message}\n#{Array(error.backtrace).join("\n")}"
  end
end
