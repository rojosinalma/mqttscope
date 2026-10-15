FROM ruby:3.3-slim

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
