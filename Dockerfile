FROM ruby:3.3-slim

LABEL org.opencontainers.image.source="https://github.com/rojosinalma/mqttscope" \
      org.opencontainers.image.description="Web explorer for an MQTT broker: live topic tree, searchable history, diffs, charts, device presence and broker stats" \
      org.opencontainers.image.licenses="AGPL-3.0-only"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libsqlite3-dev \
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 app \
    && useradd --uid 1000 --gid app --create-home --shell /usr/sbin/nologin app

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local frozen true \
    && bundle config set --local without test \
    && bundle install

COPY . .
RUN mkdir -p /app/data && chown -R app:app /app

ENV RACK_ENV=production

EXPOSE 9292

USER app

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://localhost:${PORT:-9292}/api/stats" >/dev/null || exit 1

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb", "config.ru"]
