# Data-first test harness (the bash-env pattern, evolved).
#
# Suites are plain .nu files. A test is `def "test <name>" []` — or any
# command marked with a `@test` attribute (`use std/testing *` makes the
# attribute parse). A leading `ignore` in the description, or `@ignore`,
# reports the test as skipped without running it. Optional hooks
# `def "before each"` / `def "after each"` (or `@before-each`/`@after-each`)
# wrap every test in the suite: before-each's output pipes into each test as
# $in, so hooked suites declare tests with a matching input type.
#
# Discovery and execution run in child interpreters — one per test by
# default — so suites can never poison each other, the invoking session, or
# the module state under test. Each test's literal command name is
# interpolated into the child program: nushell has no string-eval, and a
# `$name` in command position silently evaluates to the string instead of
# invoking it (the vacuous-runner trap this harness replaces)

# ---
# nu-lint-ignore-file: chained_str_transform
# ---

use std-rfc/kv [ "kv get" "kv set" "kv list" "kv drop" ]

# Marks a result row on a child's stdout; test prints pass through untagged.
const ROW: string = '#TEST-ROW#'
const KV: string = 'test_config'
const BIN: path = path self ../scripts | path expand --strict

# Register directories to be included in the `--include-path` of Nushell test subprocesses.
export def add-lib [
  ...dirs: directory # Directories to register for test subprocesses
]: oneof<nothing, list<directory>> -> list<directory> {
  append $dirs
  | uniq
  | compact --empty
  | path expand --strict
  | where ($it | path type) == dir
  | kv set --return=input --table=$KV include_path {|| str join (char esep) }
}

# Run the suites at a path and return their results as a table.
#
# Progress renders on stderr; the return value is pure data, so it pipes:
# `test tests/suites | where status == fail`.
export def main [
  path: path = tests/suites # A suite file or a directory of suite files
  --include (-i): string@_suite-stems = '.+' # Only run suites whose basename matches
  --test (-t): string@_test-names = '' # Only run tests whose command name matches
  --isolation: string@_isolation = test # Interpreter per 'test' (hermetic) or per 'suite' (fast)
  --verbose (-v) # Print captured errors under failing tests
  --strict (-s) # Raise an error when any test fails, for CI and hooks
]: nothing -> table {
  if $isolation not-in [test suite] {
    error make --unspanned $"--isolation must be 'test' or 'suite', got '($isolation)'"
  }
  let suites: list<path> = $path | path expand
    | if ($in | path type) == dir { glob ($in | path join *.nu) } else { [$in] }
    | where ($it | path basename) =~ $include
  let results: table = $suites | each {|suite|
      print --stderr $"(ansi dark_gray_bold)[(ansi rst)(ansi cyan_bold)($suite | path parse | get stem)(ansi rst)(ansi dark_gray_bold)](ansi rst)"
      let cmds: table = discover $suite
      let hooks: record = {
        before: ($cmds | where role == before-each | get --optional 0.name)
        after: ($cmds | where role == after-each | get --optional 0.name)
      }
      let wanted: table = $cmds | where role == test
        | if $test == '' { $in } else { where name =~ $test }
      # Ignored tests surface as skips: invisible skips read as coverage.
      let ignored: table = $wanted | where $it.ignore | each {|c|
          {name: $c.name status: skip error: 'ignored at discovery' duration: 0sec}
        }
      let names: list = $wanted | where not $it.ignore | get name
      let ran: table = match $isolation {
        test => ($names | each {|n| spawn $suite (snippet $n $hooks) } | flatten)
        suite => (spawn $suite ...($names | each {|n| snippet $n $hooks }))
      }
      $ran | append $ignored | each {|row|
        render $row $verbose
        $row | insert suite ($suite | path parse | get stem)
      }
    } | flatten
  summarize $results $strict
  $results | select suite name status duration error
}

# Abort the current test, reporting it as skipped instead of failed.
# For runtime conditions: a missing external tool, absent credentials, ...
export def skip [
  reason: string # Why the test cannot run here; rendered in the skip report
]: nothing -> error {
  error make --unspanned $"SKIP: ($reason)"
}

# Run a closure against a throwaway sandbox directory, cleaning up after.
#
# The closure receives {root, home, data, code}: the seam record `sandboxed`
# uses to redirect a child interpreter's $nu.home-dir and $nu.data-dir.
export def with-sandbox [
  action: closure # Receives the sandbox context record {root, home, data, code}
]: nothing -> oneof<nothing, any> {
  let root: path = mktemp --directory --tmpdir test-sandbox-XXXXXX
  let ctx: record = {
    root: $root
    home: $root
    data: ($root | path join data)
    code: ($root | path join code)
  }
  mkdir $ctx.data $ctx.code
  let result: any = try { do $action $ctx } catch {|e|
    rm --recursive --force $root
    # Rethrow by message: the span is lost, the failure (and any SKIP) is not.
    error make --unspanned $e.msg
  }
  rm --recursive --force $root
  $result
}

# Run nu code inside a sandbox-scoped child interpreter.
#
# HOME/XDG_* point into the sandbox, so parse-time consts derived from
# $nu.home-dir / $nu.data-dir land there — the module under test runs
# unmodified while the real session, data, and config stay untouched.
export def sandboxed [
  ctx: record # A `with-sandbox` context
  code: string # The nu program to run
  --prelude: string = '' # Prepended to the code, e.g. `use <module> *`
]: nothing -> record<stdout: string, stderr: string, exit_code: int> {
  let commands: string = [$prelude $code] | str join (char newline)
  with-env {
    HOME: $ctx.home
    XDG_CONFIG_HOME: ($ctx.home | path join .config)
    XDG_DATA_HOME: $ctx.data
  } { subprocess $commands }
}

# ——— utilities ————————————————————————————————————————————————————————————————

# Enumerate a suite's commands and their roles in a child interpreter.
def discover [suite: path]: nothing -> table {
  const p: path = $BIN | path join probe.nu
  let script: string = [
    $"source ($suite | to nuon)"
    $"run ($BIN | path join probe.nu) | to nuon | print"
  ] | str join '; '
  subprocess $script | match $in.exit_code {
    0 => (get $.stdout | from nuon)
    _ => {
      let help: string = get $.stderr | str trim
      let name: string = $suite | path basename
      error make --unspanned {msg: $"suite '($name)' failed to load" help: $help}
    }
  }
}

# Generate the child program fragment that runs one test and emits its row.
# The test's literal name is interpolated in: strings don't invoke, names do.
def snippet [name: string hooks: record]: nothing -> string {
  $hooks | upsert $.after {||
    match ($in | describe) { nothing => 'null' string => $'$ctx | ($in)' }
  } | default 'null' before
  | merge {qname: ($name | to nuon) name: $name row: $ROW}
  | format pattern r#'do {{
  let start = date now
  let row = try {{
    let ctx = do --env {{ {before} }}
    $ctx | {name}
    do --env {{ after }} | ignore
    {name: {qname}, status: 'ok', error: null}
  }} catch {{|e|
    let status = if ($e.msg | str starts-with 'SKIP: ') {{ 'skip' }} else {{ 'fail' }}
    {name: {qname}, status: $status, error: ($e.rendered? | default $e.msg)}
  }}
  let elapsed: duration = (date now) - $start
  print $"{row}($row | merge {{duration: $elapsed}} | to nuon | encode base64)"
}}'#
}

# Source the suite plus the given fragments in a child; collect tagged rows.
def spawn [suite: path ...snippets: string]: any -> list {
  let program: string = [$"source ($suite | to nuon)"] | append $snippets | str join "\n"
  let out: record = subprocess $program
  # Rows travel base64-encoded: nuon keeps embedded newlines raw (rendered
  # errors are multi-line), and a line-based protocol must stay single-line.
  let rows: table = $out.stdout | lines
    | where ($it | str starts-with $ROW)
    | each { str replace $ROW '' | decode base64 | decode | from nuon }
  if $out.exit_code != 0 and ($rows | length) < ($snippets | length) {
    # The child died before emitting every row: an infrastructure failure,
    # not a test failure (those are caught and always emit).
    $rows | append {name: '(child)' status: error error: $out.stderr duration: 0sec}
  } else {
    $rows
  }
}

def color []: record<status: string> -> string {
  match $in.status { ok => (ansi green) skip => (ansi yellow) _ => (ansi red) }
}

def render [row: record verbose: bool]: nothing -> nothing {
  [
    $"  ($row | color)[($row.status)](ansi rst) "
    ($row.name | str replace --regex '^test ' '')
    $" (ansi attr_dimmed)($row.duration)(ansi rst)"
  ] | str join
  | print --stderr
  if $verbose and $row.status in [fail error] and $row.error != null {
    $row.error
    | lines
    | par-each --keep-order { $"    ($in)" }
    | str join (char newline)
    | print --stderr
  }
}

def summarize [results: table strict: bool]: nothing -> nothing {
  let count: closure = {|status| $results | where status == $status | length }
  let errors: int = (do $count fail) + (do $count error)
  let total: duration = $results | get --optional duration | default [] | append 0sec | math sum
  [
    $"(ansi green)(do $count ok) passed(ansi rst)"
    $"(ansi red)($errors) failed(ansi rst)"
    $"(ansi yellow)(do $count skip) skipped(ansi rst)"
    $"(ansi attr_dimmed)in ($total)(ansi rst)"
  ] | str join ', '
  | print --stderr
  if $strict and $errors > 0 { error make --unspanned $"($errors) test\(s) failed" }
}

def subprocess [
  commands: string
]: nothing -> record<stdout: string, stderr: string, exit_code: int> {
  let include_path: string = kv get --table=$KV include_path
    | match ($in | describe) { nothing => '' string => () }
  do --capture-errors {
    ^$nu.current-exe --no-config-file --include-path=($include_path) --commands=($commands)
  } | complete
}

# ——— completions ——————————————————————————————————————————————————————————————

# Resolve the suite files visible to the command line being completed:
# the first existing path token, or the `path` argument's default.
def _suites-on-line [context: string]: nothing -> list<path> {
  let path: any = $context
    | split row --regex '\s+'
    # `drop nth 0` sheds the command token; the module's own `skip` shadows
    # the core command of that name here.
    | drop nth 0
    | compact --empty
    | where $it !~ '^-' and ($it | path exists)
    | get --optional 0
    | default tests/suites
  match ($path | path type) {
    dir => (glob ($path | path join *.nu) | sort)
    file => [$path]
    _ => []
  }
}

def _suite-stems [context: string]: nothing -> list<string> {
  _suites-on-line $context | each { path parse | get stem }
}

def _test-names [context: string]: nothing -> list<string> {
  _suites-on-line $context
  | each { open $in | parse --regex 'def "(?<name>test [^"]+)"' | get name }
  | flatten
  | sort
}

def _isolation []: nothing -> list<string> {
  [test suite]
}
