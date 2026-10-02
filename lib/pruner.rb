# frozen_string_literal: true

# STUB — owner B replaces this file. Contract: CONTRACTS.md → Pruner.
module Pruner
  class << self
    def start
      $log.warn "[prune] Pruner stub — nothing scheduled"
    end

    def run_now = { deleted_by_age: 0, deleted_by_size: 0, size_before: 0, size_after: 0, duration_s: 0.0 }

    def last_run = nil
  end
end
