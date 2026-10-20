# Changelog

## 0.1.0 (2026-10-20)

First release.

- Zero-config checks: `.env` against `.env.example` (or `.env.sample`,
  `.env.template`) for missing, empty and extra keys; `.env` git-ignored and
  not committed; other `.env.*` files committed or not ignored (warning).
- Project detection for Node (package manager from the lockfile, `engines.node`,
  `.nvmrc`, `node_modules`), Python (`uv`, `poetry`), PHP (`composer`, `vendor`),
  Ruby, Go and Rust.
- `envready.conf` with five kinds of check: `bin`, `cmd`, `env`, `file`, `var`,
  each with an optional fix after ` -> `.
- `-q` for failures only, `--json` for machine-readable output, `--no-cmd` to
  skip `cmd` checks, `--init` to write a starter `envready.conf`.
- Never prints a secret's value; the test suite plants secrets and fails if any
  appears in the output.
- Works on bash 3.2 (macOS) and later.
