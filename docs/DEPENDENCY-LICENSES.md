# Dependency licenses

The module is source only: hosts vendor `ruby/`, `react/src/` and `fixtures/` at a commit, and no gem, npm package or
bundle is published. Its dependencies are downloaded when a suite's image is built (`ruby/Dockerfile`,
`react/Dockerfile`, `scripts/lint/`, `scripts/hooks/`). Material that IS in the repository is listed in
[`NOTICE`](../NOTICE).

Read from the lockfiles at 1.0.0 (unreleased); re-check after a dependency change with the commands at the end.

## Ruby gems (`ruby/Gemfile.lock`, 35 gems)

| License | Gems |
|---|---|
| MIT | 28 |
| Ruby, or Ruby / BSD-2-Clause (dual) | 4 |
| BSD-2-Clause (`pg`, `rexml`), BSD-3-Clause (`sqlite3`) | 3 |

All permissive; nothing to act on. The runtime needs only `sequel` and `commonmarker` (MIT); the rest are test and
lint tools, plus the host's own database driver.

## npm packages (`react/package-lock.json`, 271 packages)

Two reach a host's bundle: the React port's one runtime dependency, **`@dagrejs/dagre` 3.1.3** (MIT, 17 KB min+gz —
the layered layout of the workflow graph in `BoardEditor`) and its own dependency `@dagrejs/graphlib` 4.0.6 (MIT); a host
adds `@dagrejs/dagre` to its own package.json when it vendors `react/src`. Every other package is a build or test tool
(`devDependencies` and theirs): `react` and `react-dom` are peer dependencies the host supplies. 216 MIT, 18
Apache-2.0, 10 ISC, 11 BSD, and:

| Package | License | Used for | Obligation |
|---|---|---|---|
| `lightningcss` 1.33.0 and its 11 platform binaries | MPL-2.0 | the CSS transformer of the Vite that vitest runs on | none: used unmodified at test time, not redistributed; MPL-2.0's file-level terms apply only to someone who distributes those files |
| `minimatch` 11.0.5, `@isaacs/nonrecursive-glob-match` 1.1.0 | BlueOak-1.0.0 | glob matching inside ESLint and the TypeScript tooling | none: permissive; tooling only |
| `argparse` 2.0.1 | Python-2.0 (PSF) | a dependency of ESLint's config loading (`js-yaml`) | none: permissive; tooling only |
| `@csstools/color-helpers` 5.1.0 | MIT-0 | CSS colour parsing in jsdom's stylesheet support (tests) | none: MIT without the attribution clause |

No dependency is under a copyleft license whose terms reach the module's own code.

## Re-check

```bash
# npm: every package that is not MIT / ISC / Apache-2.0 / BSD (dev = build/test only)
jq -r '.packages | to_entries[] | select(.key != "") |
  "\(.value.license // "NONE")\t\(.key | sub(".*node_modules/"; ""))\t\(if .value.dev then "dev" else "runtime" end)"' \
  react/package-lock.json | grep -vE '^(MIT|ISC|Apache-2.0|BSD-2-Clause|BSD-3-Clause)\s'

# gems: the license each installed gem declares, in the suite image (docker build -t agents-kanban-ruby:dev ruby;
# the lint group is installed only in the agents-kanban-lint image scripts/lint/rubocop builds: run the same there)
docker run --rm -v "$PWD":/w -w /w/ruby --entrypoint ruby agents-kanban-ruby:dev -rbundler -e '
  Bundler::LockfileParser.new(File.read("Gemfile.lock")).specs.map(&:name).uniq.sort.each { |n|
    s = Gem::Specification.find_all_by_name(n).first
    puts [s ? s.licenses.join("|") : "not installed here", n].join("\t") }'
```
