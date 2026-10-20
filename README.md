# envready

Is this project ready to run *here*?

`envready` is one small bash script you run after cloning a project, or after
moving it to a new laptop, container, Codespace or cloud sandbox. It checks
what the project needs (tools, versions, installed dependencies, the keys in
`.env`) and prints one line per check: `ok` or `FAIL`. Every `FAIL` comes with
the exact fix, a command to run or a page to open.

It is written for two kinds of people: someone who builds with AI tools
(Lovable, Cursor, Claude Code) and wants to know why the app will not start,
and a developer who wants a fast, honest answer before digging in. It is also
written for the AI coding agents those people use, which is why it has `-q`
and `--json`.

## 30-second start

```sh
curl -fsSL https://raw.githubusercontent.com/piorkowm/envready/main/envready -o envready && chmod +x envready && ./envready
```

Please read the script before you run it (it is one file, and plain bash).
That is good practice for anything you download and run, and this tool asks
you to trust it near your `.env` file.

Then, optionally:

```sh
./envready --init      # write a starter envready.conf for this project
./envready -q          # failures only; silent when everything passes
./envready --json      # machine-readable results
./envready path/to/project
```

It exits `0` when every check passes and `1` when anything fails (`2` for a
usage error), so it also works in scripts and CI.

## The three rules

These are the point of the tool. The tests enforce the first one.

1. **It never prints, logs or sends a secret's value.** It may say a key is
   missing or empty, never what it contains. Output from `cmd` checks is
   thrown away, for the same reason.
2. **No network, and it changes nothing.** It reads files and asks your tools
   whether they are installed. The only thing it ever writes is
   `envready.conf`, and only when you ask with `--init`; it refuses to
   overwrite one that exists.
3. **Every failure names its fix.** A check you cannot act on is a check that
   gets ignored.

One honest caveat about rule 2: a `cmd` line in `envready.conf` runs a command
the project chose. Keep those commands read-only (`gh auth status`, `docker
info`). If you are checking a project you do not trust yet, read its
`envready.conf` first, or run `./envready --no-cmd`.

## Example output

```
envready 0.1.0: /home/me/my-app

project: node (package.json)
  ok    node (/usr/local/bin/node)
  ok    pnpm (/usr/local/bin/pnpm)
  ok    node 22.11.0 matches engines.node ">=20"
  FAIL  node_modules is missing (dependencies are not installed)
        -> pnpm install

env: .env.example vs .env
  FAIL  SUPABASE_ANON_KEY is empty in .env
        -> fill in a value for SUPABASE_ANON_KEY in .env
  FAIL  STRIPE_SECRET_KEY is missing from .env
        -> add a line STRIPE_SECRET_KEY=<value> to .env (.env.example lists it)
  warn  OLD_TOKEN is in .env but not in .env.example
        -> add OLD_TOKEN= (no value) to .env.example so the next person knows it is needed, or remove it from .env if nothing uses it
  FAIL  .env is not git-ignored
        -> echo '.env' >> .gitignore

envready.conf
  FAIL  supabase is not installed (not found on PATH)
        -> npm install -g supabase
  ok    gh auth status

not ready: 5 failed, 4 passed, 1 warning. Fix each FAIL above, then run envready again.
```

Note what is not there: the value of `SUPABASE_URL`, which is set, appears
nowhere. Neither does any other value.

With `-q`, only the `FAIL` lines and their fixes are printed. With `--json`:

```json
{"tool":"envready","version":"0.1.0","dir":"/home/me/my-app","ready":false,
 "pass":4,"fail":5,"warn":1,
 "checks":[{"status":"fail","section":"project: node (package.json)",
            "check":"node_modules is missing (dependencies are not installed)",
            "fix":"pnpm install"}, ...]}
```

`status` is `ok`, `fail` or `warn`. Every `fail` has a non-empty `fix`. `-q`
has no effect on `--json`, which always lists every check.

## What it checks with no config at all

- **`.env` against `.env.example`** (or `.env.sample`, `.env.template`): keys
  missing from `.env`, keys present but empty, and keys in `.env` that the
  example does not list (a warning). A key that is missing from `.env` but set
  in the environment counts as set, so Codespaces secrets and CI variables
  work. It understands comments, blank lines, `export KEY=...`, quoted values
  and quoted values that span several lines.
- **`.env` and git**: `.env` must be git-ignored, and must not be committed.
  If it is committed, the fix tells you to take it out of the index *and* to
  rotate every key in it, because it stays in the history. Other files such as
  `.env.local` or `.env.production` get a warning if they are committed or not
  ignored.
- **Project type, then the tools it needs**:

  | file found | checks |
  |---|---|
  | `package.json` | `node`, the package manager (`pnpm`, `yarn` or `bun` from the lockfile or `packageManager`, otherwise `npm`), `engines.node` and `.nvmrc` / `.node-version` (major version), `node_modules` installed |
  | `pyproject.toml`, `requirements.txt` | `python3`; `uv` if there is `uv.lock`; `poetry` if there is `poetry.lock` |
  | `composer.json` | `php`, `composer`, `vendor` installed |
  | `Gemfile` | `ruby`, `bundle` |
  | `go.mod` | `go` |
  | `Cargo.toml` | `cargo` |

The `engines.node` check is best effort: it compares major versions, using
`node` itself to read `package.json`, so it needs no JSON tool. When it cannot
read a range it says so as a warning instead of guessing.

If envready finds nothing at all to check, that is a `FAIL`, not a pass:
usually it means you ran it in the wrong folder.

## envready.conf

For everything a project needs beyond the defaults, commit an
`envready.conf` at the project root. `./envready --init` writes a starter one
from what it detects (it suggests `gh` when there is a `.github` folder,
`supabase` when there is `supabase/config.toml`, `docker` when there is a
compose file, and so on).

One check per line:

```
# kind   target                       -> fix (printed when the check fails)
bin      gh                           -> https://cli.github.com
bin      supabase                     -> npm install -g supabase
cmd      gh auth status               -> gh auth login
env      .env.example .env
env      apps/web/.env.example apps/web/.env.local
file     .claude/settings.json        -> copy it from .claude/settings.example.json
var      OPENAI_API_KEY               -> add it to .env (see https://platform.openai.com/api-keys)
```

| kind | target | passes when |
|---|---|---|
| `bin` | a command name | it is on `PATH` |
| `cmd` | a shell command | it exits 0 (run with `sh -c`, from the project folder, output hidden, input from `/dev/null`, timeout 10s when `timeout` or `gtimeout` exists; change it with `ENVREADY_TIMEOUT=30`) |
| `env` | `EXAMPLE [ACTUAL]` | every key in EXAMPLE is set in ACTUAL (default `.env`), as described above |
| `file` | a path | it exists (a file or a folder) |
| `var` | a variable name | it is set and non-empty in the environment, or in `.env` (or any ACTUAL file from an `env` line) |

The rules of the format:

- The fix is everything after the first ` -> ` (an arrow with a space or tab
  on each side). It is optional; without one, a generic fix is printed.
- Columns are separated by any amount of spaces or tabs. Line them up or not.
- Lines starting with `#` are comments, and so are blank lines. There are no
  comments at the end of a line, so a fix can contain `#` (URLs often do).
- Paths with spaces go in quotes: `file "docs/setup guide.md"`, or
  `env "my example" "my actual"`. A `cmd` is passed to the shell as written,
  so quote inside it the way you would on the command line.
- Windows line endings are fine.
- If the file has any `env` line, the default `.env.example` check is not run;
  your `env` lines replace it. Everything else adds to the defaults. A `bin`
  that the defaults already check is not checked twice.
- A line envready cannot read is a `FAIL` that names the line number.

## For AI coding agents

Paste this into `CLAUDE.md`, `AGENTS.md`, `.cursorrules` or wherever your
agent reads project instructions:

```
Before starting work, run ./envready -q from the project root.
Fix every FAIL using the fix printed under it, then run it again until it
prints nothing. Never print, echo, cat or log the values in .env or any other
secrets file; envready only tells you which keys are missing or empty, and
that is all you need. If a fix needs a secret you do not have, ask the person.
```

For tools that parse output, `./envready --json` prints one JSON object on
stdout; check `ready`, and act on the `fix` of every check whose `status` is
`fail`.

## Why

Environments are disposable now: a new laptop, a fresh container, a
Codespace, a sandbox an agent spins up for one task. Each one has to be put
back together, and a half-restored environment looks exactly like a working
one until you trip over the missing piece. Then the error you get names
something else: a build that fails on a missing tool, an API that answers
401 because a key is empty, an agent that loops trying to fix code that was
never broken.

envready asks first, in one command, and tells you what to do about each
thing it finds.

## Requirements

bash 3.2 or later (the version macOS ships), and the usual POSIX tools
(`awk`, `sed`, `grep`, `tr`). `git` is used when the project is a git repo,
`node` when the project uses Node. Tested on Linux and macOS.

## Development

```sh
shellcheck envready test/run.sh
bash test/run.sh                        # all tests
ENVREADY_TEST_FILTER=json bash test/run.sh
ENVREADY_BASH=/bin/bash bash test/run.sh  # run envready under another bash
```

The tests build throwaway projects with real secret-looking values planted in
them, run envready every way it can be run, and then search everything it
printed for those values. A single hit fails the suite. The suite also fails
when it runs no tests at all, so a broken runner cannot look like a passing
one.

## License

MIT. See [LICENSE](LICENSE).

Made by Marcin Piórkowski, [Empes](https://empes.it).
