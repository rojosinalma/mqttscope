# frozen_string_literal: true

# STUB — owner B replaces this file. Contract: CONTRACTS.md → Sampling.
module Sampling
  class << self
    def store?(topic:, payload:, ts_ms:) = true

    def rule_for(_topic) = { pattern: nil, min_interval_ms: Setting.fetch("default_min_interval_ms", 1000) }

    def rules = []
  end
end
