# picomatch 4.0.8-busyyaks.0 (vendored)

**What:** picomatch **4.0.7** as published on npm (`npm pack picomatch@4.0.7`, identical to tag `4.0.7` of
https://github.com/micromatch/picomatch) + ONE change: `lib/parse.js` gets the fix of upstream
**micromatch/picomatch PR 237** (https://github.com/micromatch/picomatch/pull/237, commit `1bf0d04563cb9ce568cf36efc5f6b7187d9911d5`, open, not merged), its `lib/parse.js`
hunk only. `README.md` dropped (docs only); `package.json` = the published one minus `scripts` / `devDependencies` /
`keywords` / `verb` / `nyc` (dev metadata that npm would otherwise resolve into our lockfile), version renamed.

**Why:** GHSA-fc5q-39xc-vjpf (CVE-2026-112366, ReDoS on single-branch repeated extglobs such as `+(*a)`) covers
`<= 4.0.7`, every published version, and no release fixes it (the maintainer declined the report on PR 235). vitest,
tinyglobby, fdir and typescript-eslint all pull picomatch 4, so `npm audit --audit-level=low` (CI `audit`) was
red. The fix lives in the tree instead of silencing the audit.

**The version:** `4.0.8-busyyaks.0` — a prerelease ABOVE 4.0.7, so the advisory's range no longer matches the code that
is no longer vulnerable, while the package keeps its real name: `npm audit` still checks it, and any future advisory
`< 4.0.8` or wider flags it again. `react/package.json` pins it (`devDependencies` `file:vendor/picomatch` +
`overrides` `"picomatch": "$picomatch"`), `react/.npmrc` installs it as a copy.

**The fix (PR 237):** a repeated extglob `+(P)` / `*(P)` whose single branch P holds a top-level `*` (no `/`, groups,
alternation, nested extglob or globstar) absorbs its own repetition: `+(P)` → `(?:P)`, `*(P)` → `(?:P)?` — the same
language, no nested quantifier. Proved here: picomatch's own suite at 4.0.7 + the PR's tests, 1984 passing; `+(*a)` vs
`'a'.repeat(28) + 'b'`: 6358 ms on 4.0.7, 1 ms patched; `react/test/picomatch.test.ts` keeps it.

**Drop it** when picomatch publishes a release outside the advisory's range: delete this dir + `react/.npmrc`'s
reason, the `picomatch` devDependency and override, and re-lock.
