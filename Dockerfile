FROM ruby:3.2-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libpq-dev curl procps && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle install --jobs 4

COPY . .

EXPOSE 4567

# Entrypoint: run migration then start the server
CMD ["sh", "-c", "ruby db/migrate.rb && bundle exec puma -C puma.rb"]
