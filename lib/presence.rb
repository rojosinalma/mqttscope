# frozen_string_literal: true

# STUB — owner C replaces this file. Contract: CONTRACTS.md → Presence.
module Presence
  class << self
    def rules = Setting.json("presence_rules", Setting::DEFAULT_PRESENCE_RULES)

    def devices = []

    def timeline(id:, from_ms:, to_ms:) = []
  end
end
