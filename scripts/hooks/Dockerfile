# agents-kanban-hooks — every git hook runs in here, never on the host: overcommit 0.75.0 + RuboCop
# and its plugins (ruby/Gemfile's :lint group, pinned by ruby/Gemfile.lock — the same gems CI's lint stage
# runs), ESLint + Prettier with react/'s node_modules (npm ci of react/package-lock.json — the packages CI's react
# stage installs), gitleaks (the version CI's secrets stage runs) and ShellCheck (the version CI's lint stage runs).
# scripts/hooks/image tags it by the hash of every input and rebuilds on change; the build context is those inputs alone.
FROM node:22-slim AS node
WORKDIR /deps
COPY react/package.json react/package-lock.json ./
RUN npm ci --no-audit --no-fund

FROM zricethezav/gitleaks:v8.30.1 AS gitleaks

FROM koalaman/shellcheck:v0.10.0 AS shellcheck

FROM ruby:3.4-slim
# git: overcommit, the staged snapshot and gitleaks; procps: overcommit reads its parent command (`ps`);
# build-essential: native extensions of the :lint gems
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git procps \
 && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
# node_modules at /deps: the staged tree is checked out at /deps/snap, so Node's lookup from /deps/snap/react finds it
COPY --from=node /deps/node_modules /deps/node_modules
COPY --from=gitleaks /usr/bin/gitleaks /usr/local/bin/gitleaks
COPY --from=shellcheck /bin/shellcheck /usr/local/bin/shellcheck
WORKDIR /hooks-gems
COPY ruby/Gemfile ruby/Gemfile.lock ./
ENV BUNDLE_ONLY=lint BUNDLE_GEMFILE=/hooks-gems/Gemfile
RUN bundle install && bundle exec overcommit --version && bundle exec rubocop --version \
 && node --version && /deps/node_modules/.bin/eslint --version && /deps/node_modules/.bin/prettier --version \
 && gitleaks version && shellcheck --version
COPY scripts/hooks/entry scripts/hooks/overcommit.rb scripts/hooks/eslint scripts/hooks/gitleaks scripts/hooks/prettier \
     scripts/hooks/shellcheck scripts/lint/shell-files /hooks/
WORKDIR /deps/snap
ENTRYPOINT ["/hooks/entry"]
