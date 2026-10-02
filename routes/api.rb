# frozen_string_literal: true

# STUB — owner D replaces this file. Contract: CONTRACTS.md → HTTP API.
class App
  hash_branch "api" do |r|
    r.get "stats" do
      json_ok("ok", ingest: ::Ingest.status, db: ::Store.stats, sys: ::Store.sys_latest,
                    sse_clients: ::Bus.client_count, prune: ::Pruner.last_run)
    end
  end
end
