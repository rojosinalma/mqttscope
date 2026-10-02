require "dotenv"
Dotenv.load(File.expand_path(".env", __dir__))

require "rack/unreloader"

dev = ENV["RACK_ENV"] == "development"
require_relative "lib/logger"

# Only the app's own constants are unloaded; gems required from reloadable
# files would otherwise be attributed to them and torn down on reload.
RELOADABLE = %w[Roda Sequel::Model TopicMatch TopicRegistry Sampling Store Differ Presence].freeze
Unreloader = Rack::Unreloader.new(subclasses: RELOADABLE, reload: dev, logger: ($log if dev)) { App }
Unreloader.require(File.expand_path("app.rb", __dir__)) { "App" }

Setting.seed_defaults!
TopicRegistry.warm(Store.topics)
Ingest.start
Pruner.start

run(dev ? Unreloader : App.freeze.app)
