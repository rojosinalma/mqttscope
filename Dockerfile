FROM ruby:3.3-slim

LABEL org.opencontainers.image.source="https://github.com/rojosinalma/mqttscope" \
      org.opencontainers.image.description="Web explorer for an MQTT broker: live topic tree, searchable history, diffs, charts, device presence and broker stats" \
      org.opencontainers.image.licenses="MIT"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libsqlite3-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install

COPY . .

ENV RACK_ENV=production

EXPOSE 9292

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb", "config.ru"]
