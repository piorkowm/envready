#!/usr/bin/env bash
# Tests are called by name from the list at the bottom, which shellcheck
# cannot follow.
# shellcheck disable=SC2329
#
# Test harness for envready. No dependencies beyond bash, git and python3
# (python3 only to check that --json output parses).
#
#   bash test/run.sh                         every test
#   ENVREADY_TEST_FILTER=json bash test/run.sh   tests whose name contains "json"
#   ENVREADY_BASH=/bin/bash bash test/run.sh     run envready under another bash
#
# Each test builds its own fixture project in a temporary directory. Every
# line envready prints, across every test, is kept, and at the end the whole
# lot is searched for the secret values planted in those fixtures. One hit
# fails the run, whatever else passed.
#
# A harness that ran nothing must not look green: zero tests run is a failure,
# a test that makes no assertion is a failure, and test_harness_guards checks
# both by running this file against a filter that matches nothing and against
# an envready that does not exist.

set -u

nl='
'
root=$(cd "$(dirname "$0")/.." && pwd)
er=${ENVREADY:-$root/envready}
sh_bin=${ENVREADY_BASH:-$BASH}
filter=${ENVREADY_TEST_FILTER:-}

if [ ! -f "$er" ]; then
  echo "FAIL  envready not found at $er; nothing was tested" >&2
  exit 1
fi

# Values that must never appear in envready's output. Distinctive, so a hit
# can only be a leak.
secret='sk-planted-7f3a9c1e-DO-NOT-PRINT'
secret_pem='planted-pem-body-4b2d8e'
secret_env='env-planted-55aa01-DO-NOT-PRINT'

tmp=$(mktemp -d "${TMPDIR:-/tmp}/envready-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# No symlinks or doubled slashes (macOS TMPDIR has both), so paths envready
# prints compare equal to the ones the tests built.
tmp=$(cd "$tmp" && pwd -P)

ran=0
failed=0
asserts=0
test_failed=0
all_out=""
out=""
rc=0

# --- helpers ------------------------------------------------------------------

fail() {
  test_failed=1
  printf '        %s\n' "$1"
}

# mkproj NAME: a fresh git repo at $tmp/NAME, path in $p.
mkproj() {
  p="$tmp/$1"
  mkdir -p "$p"
  git -C "$p" init -q
  git -C "$p" config user.email test@example.com
  git -C "$p" config user.name test
}

# er_run DIR [ARGS...]: run envready in DIR; output (stdout and stderr) in
# $out, exit status in $rc. Extra environment goes in $er_env (VAR=value ...).
er_env=""
er_run() {
  local d=$1; shift
  # shellcheck disable=SC2086
  out=$(cd "$d" && env NO_COLOR=1 $er_env "$sh_bin" "$er" ${1+"$@"} 2>&1)
  rc=$?
  all_out="$all_out$out
"
  er_env=""
}

# A PATH holding only what envready itself needs, so "not installed" tests do
# not depend on what this machine happens to have.
minpath="$tmp/minbin"
mkdir -p "$minpath"
for t in bash sh env awk sed grep tr cat head git printenv timeout gtimeout dirname mktemp; do
  if loc=$(command -v "$t" 2>/dev/null) && [ -n "$loc" ]; then
    ln -s "$loc" "$minpath/$t"
  fi
done

assert_rc() {
  asserts=$((asserts + 1))
  [ "$rc" = "$1" ] || fail "expected exit $1, got $rc"
}
assert_has() {
  asserts=$((asserts + 1))
  case "$out" in *"$1"*) ;; *) fail "expected output to contain: $1" ;; esac
}
assert_lacks() {
  asserts=$((asserts + 1))
  case "$out" in *"$1"*) fail "expected output NOT to contain: $1" ;; esac
}
show_out() {
  printf '%s\n' "$out" | sed 's/^/          | /'
}

# Standard fixture: example with three keys, .env with all three set, ignored.
good_env() {
  printf 'ER_T_ONE=\nER_T_TWO=\n# a comment\nexport ER_T_THREE=\n' > "$p/.env.example"
  printf 'ER_T_ONE=%s\nER_T_TWO="%s"\nER_T_THREE=%s # note\n' "$secret" "$secret" "$secret" > "$p/.env"
  printf '.env\n' > "$p/.gitignore"
}

# --- tests --------------------------------------------------------------------

test_all_good() {
  mkproj all_good; good_env
  er_run "$p"
  assert_rc 0
  assert_has "all 3 keys from .env.example are set in .env"
  assert_has ".env is git-ignored"
  assert_has "ready: "
  assert_lacks "FAIL"
}

test_missing_key() {
  mkproj missing_key; good_env
  printf 'ER_T_ONE=%s\nER_T_THREE=%s\n' "$secret" "$secret" > "$p/.env"
  er_run "$p"
  assert_rc 1
  assert_has "FAIL  ER_T_TWO is missing from .env"
  assert_has "-> add a line ER_T_TWO=<value> to .env"
}

test_empty_key() {
  mkproj empty_key; good_env
  printf 'ER_T_ONE=%s\nER_T_TWO=""\nER_T_THREE= # empty, only a comment\n' "$secret" > "$p/.env"
  er_run "$p"
  assert_rc 1
  assert_has "FAIL  ER_T_TWO is empty in .env"
  assert_has "FAIL  ER_T_THREE is empty in .env"
  assert_lacks "ER_T_ONE is"
}

test_key_from_environment() {
  mkproj from_env; good_env
  printf 'ER_T_ONE=%s\nER_T_THREE=%s\n' "$secret" "$secret" > "$p/.env"
  er_env="ER_T_TWO=$secret_env"
  er_run "$p"
  assert_rc 0
  assert_has "1 of them in the environment"
}

test_extra_key_warning() {
  mkproj extra_key; good_env
  printf 'ER_T_EXTRA=%s\n' "$secret" >> "$p/.env"
  er_run "$p"
  assert_rc 0
  assert_has "warn  ER_T_EXTRA is in .env but not in .env.example"
  assert_has "-> add ER_T_EXTRA= (no value) to .env.example"
}

test_env_file_missing() {
  mkproj no_env; good_env; rm "$p/.env"
  er_run "$p"
  assert_rc 1
  assert_has "FAIL  .env does not exist"
  assert_has "-> cp '.env.example' '.env'"
}

test_env_not_ignored() {
  mkproj not_ignored; good_env; rm "$p/.gitignore"
  er_run "$p"
  assert_rc 1
  assert_has "FAIL  .env is not git-ignored"
  assert_has "-> echo '.env' >> .gitignore"
}

test_env_tracked() {
  mkproj tracked; good_env
  git -C "$p" add -f .env .gitignore
  git -C "$p" commit -q -m fixture
  er_run "$p"
  assert_rc 1
  assert_has "FAIL  .env is committed to git"
  assert_has "git rm --cached '.env'"
  assert_has "rotate every key"
}

test_other_env_files() {
  mkproj other_env; good_env
  printf 'X=%s\n' "$secret" > "$p/.env.production"
  printf 'X=%s\n' "$secret" > "$p/.env.local"
  printf 'X=\n' > "$p/.env.local.example"
  printf '.env\n.env.local\n' > "$p/.gitignore"
  git -C "$p" add .env.production
  git -C "$p" commit -q -m fixture
  er_run "$p"
  assert_rc 0
  assert_has "warn  .env.production is committed to git"
  assert_has "ok    .env.local is git-ignored"
  assert_lacks ".env.local.example is"
  rm "$p/.gitignore"
  er_run "$p"
  assert_has "warn  .env.local is not git-ignored"
}

test_sample_and_template_names() {
  mkproj sample; good_env; mv "$p/.env.example" "$p/.env.sample"
  er_run "$p"
  assert_rc 0
  assert_has "env: .env.sample vs .env"
  mkproj template; good_env; mv "$p/.env.example" "$p/.env.template"
  er_run "$p"
  assert_has "env: .env.template vs .env"
}

test_crlf_and_quotes() {
  mkproj crlf
  printf 'ER_T_ONE=\r\nER_T_TWO=\r\n' > "$p/.env.example"
  printf "ER_T_ONE='%s'\r\nER_T_TWO=\"a \\\\\" b\"\r\n" "$secret" > "$p/.env"
  printf '.env\n' > "$p/.gitignore"
  er_run "$p"
  assert_rc 0
  assert_has "all 2 keys"
}

test_multiline_value_is_not_parsed_as_keys() {
  mkproj multiline
  printf 'ER_T_PEM=\n' > "$p/.env.example"
  printf 'ER_T_PEM="-----BEGIN KEY-----\nZZLEAK=%s\n%s==\n-----END KEY-----"\n' "$secret_pem" "$secret_pem" > "$p/.env"
  printf '.env\n' > "$p/.gitignore"
  er_run "$p"
  assert_rc 0
  assert_lacks "ZZLEAK"
  assert_lacks "warn"
}

test_missing_binary_detected() {
  mkproj gomod
  printf 'module example.com/x\n' > "$p/go.mod"
  er_env="PATH=$minpath"
  er_run "$p"
  assert_rc 1
  assert_has "FAIL  go is not installed (not found on PATH)"
  assert_has "-> install Go from https://go.dev/dl/"
}

test_node_modules_missing() {
  mkproj node_modules
  printf '{"name":"x","dependencies":{"left-pad":"1.0.0"}}\n' > "$p/package.json"
  : > "$p/pnpm-lock.yaml"
  er_env="PATH=$minpath"
  er_run "$p"
  assert_rc 1
  assert_has "FAIL  node is not installed"
  assert_has "FAIL  pnpm is not installed"
  assert_has "-> npm install -g pnpm"
  assert_has "FAIL  node_modules is missing"
  assert_has "-> pnpm install"
}

test_engines_node() {
  mkproj engines
  if ! command -v node >/dev/null 2>&1; then
    printf '{"engines":{"node":">=18"}}\n' > "$p/package.json"
    er_run "$p"
    assert_has "node is not installed"
    return 0
  fi
  printf '{"engines":{"node":">=999"}}\n' > "$p/package.json"
  er_run "$p"
  assert_rc 1
  assert_has "does not match engines.node \">=999\""
  printf '{"engines":{"node":">= 4 || ^2"}}\n' > "$p/package.json"
  er_run "$p"
  assert_has "matches engines.node"
}

test_conf_bin() {
  mkproj conf_bin
  printf '# comment\n\nbin   envready-no-such-binary-xyz   ->   see https://example.com/install\nbin sh\n' > "$p/envready.conf"
  er_run "$p"
  assert_rc 1
  assert_has "FAIL  envready-no-such-binary-xyz is not installed"
  assert_has "-> see https://example.com/install"
  assert_has "ok    sh ("
}

test_conf_cmd() {
  mkproj conf_cmd
  printf 'ER_T_ONE=%s\n' "$secret" > "$p/.env"
  printf '.env\n' > "$p/.gitignore"
  {
    printf 'cmd  test -d . && true          -> nothing to do\n'
    printf 'cmd  false                      -> run the fixer\n'
    # Prints the secret on both streams: envready must show neither.
    printf 'cmd  cat .env; cat .env >&2; exit 3\n'
  } > "$p/envready.conf"
  er_run "$p"
  assert_rc 1
  assert_has "ok    test -d . && true"
  assert_has "FAIL  false (exit 1)"
  assert_has "-> run the fixer"
  assert_has "(exit 3)"
  assert_has "-> run it yourself to see why"
  er_run "$p" --no-cmd
  assert_rc 0
  assert_has "skipped (--no-cmd)"
}

test_conf_cmd_timeout() {
  mkproj conf_timeout
  if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    printf 'cmd sleep 0 -> x\n' > "$p/envready.conf"
    er_run "$p"
    assert_rc 0
    return 0
  fi
  printf 'cmd sleep 5 -> it hangs\n' > "$p/envready.conf"
  er_env="ENVREADY_TIMEOUT=1"
  er_run "$p"
  assert_rc 1
  assert_has "timed out after 1s"
}

test_conf_var() {
  mkproj conf_var
  printf 'ER_T_FILEVAR=%s\nER_T_EMPTYVAR=\n' "$secret" > "$p/.env"
  printf '.env\n' > "$p/.gitignore"
  {
    printf 'var ER_T_ENVVAR   -> export it\n'
    printf 'var ER_T_FILEVAR\n'
    printf 'var ER_T_EMPTYVAR -> fill it in\n'
    printf 'var ER_T_NOWHERE  -> get one at https://example.com/keys\n'
    printf 'var 9bad-name\n'
  } > "$p/envready.conf"
  er_env="ER_T_ENVVAR=$secret_env"
  er_run "$p"
  assert_rc 1
  assert_has "ok    ER_T_ENVVAR is set (environment)"
  assert_has "ok    ER_T_FILEVAR is set (.env)"
  assert_has "FAIL  ER_T_EMPTYVAR is empty in .env"
  assert_has "FAIL  ER_T_NOWHERE is not set"
  assert_has "-> get one at https://example.com/keys"
  assert_has "is not a valid variable name"
}

test_conf_file_and_quoting() {
  mkproj conf_file
  mkdir -p "$p/dir with space"
  : > "$p/dir with space/settings.json"
  printf 'K=\n' > "$p/my example"
  printf 'K=%s\n' "$secret" > "$p/my actual"
  printf 'my actual\n' > "$p/.gitignore"
  {
    printf 'file "dir with space/settings.json"   -> copy it\n'
    printf "file 'missing file.txt'              -> \"create it\"\n"
    printf 'env  "my example" "my actual"\n'
  } > "$p/envready.conf"
  er_run "$p"
  assert_rc 1
  assert_has "ok    dir with space/settings.json exists"
  assert_has "FAIL  missing file.txt does not exist"
  assert_has "-> create it"
  assert_has "env: my example vs my actual"
  assert_has "all 1 keys from my example are set in my actual"
}

test_conf_env_replaces_default() {
  mkproj conf_env; good_env
  mv "$p/.env" "$p/.env.local"
  printf '.env.local\n' > "$p/.gitignore"
  printf 'env .env.example .env.local\n' > "$p/envready.conf"
  er_run "$p"
  assert_rc 0
  assert_has "env: .env.example vs .env.local"
  assert_lacks "env: .env.example vs .env$nl"
}

test_conf_errors_name_line() {
  mkproj conf_err
  printf 'bin ok-thing\nfrobnicate x\nfile\n' > "$p/envready.conf"
  er_run "$p"
  assert_rc 1
  assert_has "envready.conf line 2: unknown kind \"frobnicate\""
  assert_has "-> use one of: bin cmd env file var"
  assert_has "envready.conf line 3: \"file\" has nothing to check"
}

test_quiet() {
  mkproj quiet_ok; good_env
  er_run "$p" -q
  assert_rc 0
  asserts=$((asserts + 1))
  [ -z "$out" ] || { fail "-q on a passing project should print nothing"; show_out; }
  mkproj quiet_fail; good_env; rm "$p/.gitignore"
  printf 'ER_T_EXTRA=%s\n' "$secret" >> "$p/.env"
  er_run "$p" -q
  assert_rc 1
  assert_has "FAIL  .env is not git-ignored"
  assert_lacks "ok    "
  assert_lacks "warn"
  assert_lacks "envready 0.1"
}

test_json() {
  mkproj json; good_env; rm "$p/.gitignore"
  printf 'bin envready-no-such-binary-xyz -> say "hi" \\ then	tab\n' > "$p/envready.conf"
  er_run "$p" --json
  assert_rc 1
  asserts=$((asserts + 1))
  if ! printf '%s' "$out" | python3 -I -m json.tool >/dev/null 2>&1; then
    fail "--json output is not valid JSON"; show_out
  fi
  asserts=$((asserts + 1))
  if ! printf '%s' "$out" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
assert d["ready"] is False, d["ready"]
assert d["fail"] == 2, d["fail"]
assert d["pass"] + d["fail"] + d["warn"] == len(d["checks"])
fixes = [c["fix"] for c in d["checks"] if c["status"] == "fail"]
assert all(fixes), fixes
assert any(f == "say \"hi\" \\ then\ttab" for f in fixes), fixes
' 2>&1; then
    fail "--json content is wrong"; show_out
  fi
  mkproj json_ok; good_env
  er_run "$p" --json
  assert_rc 0
  assert_has '"ready":true'
}

test_dir_argument() {
  mkproj dirarg; good_env
  out=$(cd "$tmp" && env NO_COLOR=1 "$sh_bin" "$er" "$p" 2>&1); rc=$?
  all_out="$all_out$out
"
  assert_rc 0
  assert_has "envready 0.1.0: $p"
  er_run "$tmp" "$tmp/does-not-exist"
  assert_rc 2
}

test_nothing_to_check() {
  mkdir -p "$tmp/empty"
  er_run "$tmp/empty"
  assert_rc 1
  assert_has "FAIL  nothing to check"
  assert_has "-> run envready from the project's root folder"
}

test_init() {
  mkproj init; good_env
  printf '{"dependencies":{}}\n' > "$p/package.json"
  mkdir -p "$p/.github" "$p/supabase"; : > "$p/supabase/config.toml"
  er_run "$p" --init
  assert_rc 0
  assert_has "wrote"
  asserts=$((asserts + 1))
  grep -q '^env      .env.example .env$' "$p/envready.conf" || fail "init did not write the env line"
  asserts=$((asserts + 1))
  grep -q '^bin      supabase' "$p/envready.conf" || fail "init did not suggest supabase"
  printf '# hand edit\n' >> "$p/envready.conf"
  er_run "$p" --init
  assert_rc 1
  assert_has "already exists"
  asserts=$((asserts + 1))
  grep -q '^# hand edit$' "$p/envready.conf" || fail "init overwrote an existing envready.conf"
  er_run "$p" --no-cmd
  assert_lacks "unknown kind"
  assert_lacks "has nothing to check"
}

test_usage() {
  er_run "$tmp" --bogus
  assert_rc 2
  er_run "$tmp" --version
  assert_rc 0
  assert_has "envready 0.1.0"
  er_run "$tmp" --help
  assert_rc 0
  assert_has "usage: envready"
}

# A runner that resolves nothing must not look green.
test_harness_guards() {
  if [ -n "${ENVREADY_TEST_NESTED:-}" ]; then
    asserts=$((asserts + 1)); return 0
  fi
  out=$(ENVREADY_TEST_NESTED=1 ENVREADY_TEST_FILTER=__matches_no_test__ "$sh_bin" "$0" 2>&1); rc=$?
  asserts=$((asserts + 1))
  [ "$rc" != 0 ] || fail "harness exited 0 with no tests run"
  assert_has "no tests ran"
  out=$(ENVREADY_TEST_NESTED=1 ENVREADY="$tmp/no-such-envready" "$sh_bin" "$0" 2>&1); rc=$?
  asserts=$((asserts + 1))
  [ "$rc" != 0 ] || fail "harness exited 0 with envready missing"
  assert_has "nothing was tested"
}

# --- runner -------------------------------------------------------------------

tests="
test_all_good
test_missing_key
test_empty_key
test_key_from_environment
test_extra_key_warning
test_env_file_missing
test_env_not_ignored
test_env_tracked
test_other_env_files
test_sample_and_template_names
test_crlf_and_quotes
test_multiline_value_is_not_parsed_as_keys
test_missing_binary_detected
test_node_modules_missing
test_engines_node
test_conf_bin
test_conf_cmd
test_conf_cmd_timeout
test_conf_var
test_conf_file_and_quoting
test_conf_env_replaces_default
test_conf_errors_name_line
test_quiet
test_json
test_dir_argument
test_nothing_to_check
test_init
test_usage
test_harness_guards
"

# shellcheck disable=SC2016
echo "envready tests: $er (bash: $("$sh_bin" -c 'echo "$BASH_VERSION"'))"
for t in $tests; do
  case "$t" in *"$filter"*) ;; *) continue ;; esac
  ran=$((ran + 1))
  asserts=0
  test_failed=0
  "$t"
  if [ "$asserts" = 0 ]; then
    fail "test made no assertions"
  fi
  if [ "$test_failed" = 0 ]; then
    printf '  ok    %s\n' "$t"
  else
    failed=$((failed + 1))
    printf '  FAIL  %s\n' "$t"
  fi
done

if [ "$ran" = 0 ]; then
  echo "FAIL  no tests ran (filter: '$filter'); a run that checks nothing is not a pass" >&2
  exit 1
fi

# The point of the tool: no planted secret appears in anything it printed.
# First prove the secrets were really planted, so this cannot pass vacuously.
planted=0
for s in "$secret" "$secret_pem"; do
  grep -rqF -- "$s" "$tmp" && planted=$((planted + 1))
done
case "$all_out" in
  "") echo "FAIL  no envready output was captured; the leak check would be empty" >&2; failed=$((failed + 1)) ;;
esac
leaked=0
for s in "$secret" "$secret_pem" "$secret_env"; do
  case "$all_out" in *"$s"*) leaked=1 ;; esac
done
if [ "$leaked" = 1 ]; then
  echo "  FAIL  secret_never_printed: a planted secret value appears in envready output"; printf "%s\n" "$all_out" | grep -nF -e "$secret" -e "$secret_pem" -e "$secret_env" | sed "s/^/          | /"
  failed=$((failed + 1))
elif [ "$planted" = 0 ] && [ -z "$filter" ]; then
  echo "  FAIL  secret_never_printed: no fixture contained a planted secret, so nothing was proven"
  failed=$((failed + 1))
else
  echo "  ok    secret_never_printed ($(printf '%s' "$all_out" | wc -l | tr -d ' ') output lines searched)"
fi

echo
if [ "$failed" = 0 ]; then
  echo "all $ran tests passed"
  exit 0
fi
echo "$failed of $ran tests failed"
exit 1
