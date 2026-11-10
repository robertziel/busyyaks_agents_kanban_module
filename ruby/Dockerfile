# The suite runs INSIDE this image (nothing is installed on the host):
#   docker build -t agents-kanban-ruby:dev ruby
#   docker run --rm -v "$PWD":/app -w /app/ruby agents-kanban-ruby:dev bundle exec rake test:parallel   # SQLite
#   docker run --rm -v "$PWD":/app -w /app/ruby -e DATABASE_URL=postgres://… agents-kanban-ruby:dev bundle exec rake test:parallel
# ruby:3.4-slim = busyyaks's runtime; commonmarker ships a native extension, hence build-essential; libpq for pg.
FROM ruby:3.4-slim
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libyaml-dev libpq-dev git sqlite3 \
 && rm -rf /var/lib/apt/lists/* && git config --system --add safe.directory '*'
WORKDIR /app/ruby
COPY Gemfile Gemfile.lock* ./
# the :lint group (RuboCop, overcommit) runs in scripts/lint/image and scripts/hooks/image, never in the suite
ENV BUNDLE_WITHOUT=lint
RUN bundle install
