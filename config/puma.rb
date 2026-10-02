# Single process on purpose: the MQTT client, Bus subscribers and the pruner
# live in memory and must be shared by every request.
threads 4, 16
bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 9292)}"
environment ENV.fetch("RACK_ENV", "development")
