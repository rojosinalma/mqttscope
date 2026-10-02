# frozen_string_literal: true

require "json"
require "roda"
require "rack/utils"

require_relative "lib/logger"
require_relative "models/database"
require_relative "lib/worker_pool"
require_relative "lib/bus"
require_relative "lib/ingest"
require_relative "lib/pruner"

APP_VERSION = File.read(File.expand_path("VERSION", __dir__)).strip.freeze

# Stateful modules above load once; everything below reloads in development.
%w[
  models/setting models/topic models/message
  lib/topic_match lib/topic_registry lib/sampling lib/store lib/differ lib/presence
].each do |file|
  defined?(Unreloader) ? Unreloader.require(File.expand_path("#{file}.rb", __dir__)) : require_relative(file)
end

class App < Roda
  opts[:root] = __dir__

  plugin :render, engine: "erb", views: "views", layout: "layout", escape: true
  plugin :json
  plugin :json_parser, content_type_regexp: %r{\Aapplication/json\b}i, error_handler: lambda { |r|
    r.halt [400, { "content-type" => "application/json" }, [JSON.generate(ok: false, message: "Request body is not valid JSON")]]
  }
  plugin :public, headers: { "cache-control" => "public, max-age=31536000, immutable" }
  plugin :halt
  plugin :head
  plugin :all_verbs
  plugin :request_headers
  plugin :streaming
  plugin :hash_branches

  plugin :not_found do
    if api_path?
      response["content-type"] = "application/json"
      JSON.generate(ok: false, message: "No route for #{request.request_method} #{request.path}")
    else
      page("not_found", title: "Not found")
    end
  end

  plugin :error_handler do |e|
    $log.error "[http] #{request.request_method} #{request.path}: #{e.class}: #{e.message}\n#{Array(e.backtrace).join("\n")}"
    response.status = 500
    if api_path?
      response["content-type"] = "application/json"
      JSON.generate(ok: false, message: "Internal error: #{e.class}: #{e.message}")
    else
      response["content-type"] = "text/plain; charset=utf-8"
      "Internal error: #{e.class}: #{e.message}"
    end
  end

  def json_ok(message, **data) = { ok: true, message: message, **data }

  def json_err(message, **data) = { ok: false, message: message, **data }

  def api_path? = request.path.start_with?("/api/")

  def halt_json(status, message, **data)
    request.halt [status, { "content-type" => "application/json" }, [JSON.generate(json_err(message, **data))]]
  end

  # Query params arrive as strings; these coerce and validate at the boundary.
  def int_param(name, default = nil, min: nil, max: nil)
    raw = request.params[name]
    return default if raw.nil? || raw.to_s.empty?

    value = Integer(raw, 10)
    halt_json(400, "#{name} must be >= #{min}") if min && value < min
    halt_json(400, "#{name} must be <= #{max}") if max && value > max
    value
  rescue ArgumentError
    halt_json(400, "#{name} must be an integer")
  end

  def asset(path)
    file = File.join(opts[:root] || Dir.pwd, "public", path)
    "/#{path}?v=#{File.exist?(file) ? File.mtime(file).to_i : 0}"
  end

  def page(template, title:, nav: nil, **locals)
    view(template, locals: locals, layout_opts: { locals: { title: title, nav: nav } })
  end

  Dir[File.join(__dir__, "routes", "*.rb")].sort.each do |file|
    defined?(Unreloader) ? Unreloader.require(file) : require(file)
  end

  route do |r|
    r.public
    r.hash_branches
  end
end
