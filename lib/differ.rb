# frozen_string_literal: true

# STUB — owner C replaces this file. Contract: CONTRACTS.md → Differ.
module Differ
  class << self
    def classify(payload)
      return :empty if payload.nil? || payload.empty?

      JSON.parse(payload)
      :json
    rescue JSON::ParserError
      payload.dup.force_encoding(Encoding::UTF_8).valid_encoding? ? :text : :binary
    end

    def diff(_old_payload, _new_payload) = { kind: "same", summary: "stub", changes: [] }

    def flatten(_json) = {}

    def numeric_paths(_payload) = []
  end
end
