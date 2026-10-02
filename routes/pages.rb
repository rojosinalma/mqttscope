# frozen_string_literal: true

# HTML pages. Each is a static shell; the page's script in public/js/ fills it from /api/*.
class App
  hash_branch "" do |r|
    r.get(true) { page("index", title: "Explorer · mqttscope", nav: "explorer") }
  end

  hash_branch "stats" do |r|
    r.get(true) { page("stats", title: "Stats · mqttscope", nav: "stats") }
  end

  hash_branch "devices" do |r|
    r.get(true) { page("devices", title: "Devices · mqttscope", nav: "devices") }
  end

  hash_branch "settings" do |r|
    r.get(true) { page("settings", title: "Settings · mqttscope", nav: "settings") }
  end
end
