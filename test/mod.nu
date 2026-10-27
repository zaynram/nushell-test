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

use std-rfc/pb
use std-rfc/kv [ "kv get" "kv set" "kv list" "kv drop" ]

# Marks a result row on a child's stdout; test prints pass through untagged.
const ROW: string = '#TEST-ROW#'
const KV: string = 'test_config'
const ROLES: list<string> = [
  test
  ignore
  before-each
  after-each
  before-all
  after-all
]

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
  path?: directory # A suite file or a directory of suite files
  --include (-i): string@_suite-stems = '.+' # Only run suites whose basename matches
  --test (-t): string@_test-names = '' # Only run tests whose command name matches
  --isolation: string@_isolation = test # Interpreter per 'test' (hermetic) or per 'suite' (fast)
  --verbose (-v) # Print captured errors under failing tests
  --debug (-d) # Print debug information (useful for collection errors)
  --strict (-s) # Raise an error when any test fails, for CI and hooks
]: nothing -> table {
  if $isolation not-in [test suite] {
    error make --unspanned $"--isolation must be 'test' or 'suite', got '($isolation)'"
  }
  let suites: list<path> = $path
    | default ($env.pwd! | path join tests suites)
    | if $debug { debug echo 'suites-root' } else { }
    | try { path expand --strict } catch { error make 'unable to resolve test suites directory' }
    | match ($in | path type) { dir => (try { glob ($in | path join *.nu) }) _ => ([$in]) }
    | default []
    | where ($it | path basename) =~ $include
    | if $debug { debug echo 'discovered-suites' } else { }
  let results: table = $suites | each {|suite|
      print --stderr $"(ansi dark_gray_bold)[(ansi rst)(ansi cyan_bold)($suite | path parse | get stem)(ansi rst)(ansi dark_gray_bold)](ansi rst)"
      let cmds: table = discover $suite
      let stem: string = $suite | path parse | get $.stem
      let hooks: record = $cmds
        | reject $.ignore
        | group-by --to-table --prune role
        | select $.role $.items.name
        | transpose --ignore-titles --header-row --as-record
        | default [] before-each after-each before-all after-all
      let wanted: table = $cmds | where role == test | if $test != '' { where name =~ $test } else { }
      # Ignored tests surface as skips: invisible skips read as coverage.
      let ignored: table = $wanted
        | where $it.ignore
        | select $.name
        | par-each --keep-order {
          let row = merge {status: skip error: 'ignored at discovery' duration: 0ms}
          render $row $verbose
          $row
        }
      let names: list = $wanted | where not $it.ignore | get name
      let count: int = $names | length
      let ran: table = match $isolation {
        test => {
          $names | enumerate | each --flatten {|row|
            pb set-idx $row.index $count
            let res = spawn $suite ($hooks | snippet $row.item)
            for row in $res { render $row $verbose }
            $res
          }
        }
        suite => {
          pb set 0
          let all: list<string> = $names | par-each --keep-order {|n| $hooks | snippet $n }
          let res = spawn $suite ...$all
          pb set 100
          for row in $res { render $row $verbose }
          $res
        }
      }
      [...$ran ...$ignored] | insert $.suite $stem
    } | flatten
  pb clear
  summarize $results $strict
  $results | select $.suite $.name $.status $.duration $.error
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

def "debug echo" [label: string]: oneof<nothing, any> -> oneof<nothing, any> {
  debug | print $"(ansi y)[debug](ansi rst) ($label): ($in)"; return $in
}

# Enumerate a suite's commands and their roles in a child interpreter.
export def discover [
  suite: path # Path to a test suite to source
]: nothing -> table<name: string, role: string, ignore: bool> {
  let commands: string = (
    $"source '($suite)'; "
    + r#'scope commands
      | where type == custom
      | select $.name $.description $.attributes.name?
      | rename --column={attributes.name: attrs}
      | to nuon --serialize
      '#
  )
  subprocess --pipe $commands
  | rename --column={attributes.name: attrs}
  | par-each --keep-order {|c|
    | insert $.role {|row|
      match ($row.name | split words | take 2) {
        [test _] => 'test'
        [$x $y] if [before after] has $x and [each all] has $y => $'($x)-($y)'
        _ => ($row.attrs | where $ROLES has $it | first)
      } | default 'none'
    } | insert $.ignore ($in.description =~ '(?i)^\s*ignore' or 'ignore' in $in.attrs)
    | select $.name $.role $.ignore
  } | where role != 'none'
  | reverse
}

# Generate the child program fragment that runs one test and emits its row.
# The test's literal name is interpolated in: strings don't invoke, names do.
export def snippet [name: string]: record -> string {
  {
    name: $name
    qname: ($name | to nuon)
    row: $ROW
    setup: ($in.before-all | str join '; ')
    before: ($in.before-each | prepend '$ctx' | str join ' | ')
    after: ($in.after-each | prepend '$ctx' | str join ' | ')
    cleanup: ($in.after-all | str join '; ')
  }
  | format pattern r#'do {{
  let start = date now
  let ctx = do --env {{ {setup} }}
  let row = try {{
    let ctx = do --env {{ {before} }}
    $ctx | {name}
    do --env {{ after }} | ignore
    {{name: {qname}, status: 'ok', error: null}}
  }} catch {{|e|
    {{
      name: {qname}
      status: (if $e.msg starts-with 'SKIP: ' {{ 'skip' }} else {{ 'fail' }})
      error: (
        match $e {{
          {{rendered: $r}} => (
            $r | lines | let ls
            | where $it starts-with snippet
            | str trim
            | compact --empty
            | str join (char newline)
            | prepend ($ls | take 1 | str replace 'Error' 'reason')
          )
          _ => $e.msg
        }}
      )
    }}
  }}
  let elapsed: duration = (date now) - $start
  print $"{row}($row | merge {{duration: $elapsed}} | to nuon | encode base64)"
  do --env {{ {cleanup} }} | ignore
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
  | print --stderr $in
  if $verbose and $row.status in [fail error] and $row.error != null {
    $row.error
    | lines
    | par-each --keep-order { $"    ($in)" }
    | str join (char newline)
    | print --stderr $in
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
  | print --stderr $in
  if $strict and $errors > 0 { error make --unspanned $"($errors) test\(s) failed" }
}

export def subprocess [
  commands: string
  --pipe # Attempt to deserialize stdout (raises an error for non-zero exit codes)
]: nothing -> oneof<record<stdout: string, stderr: string, exit_code: int>, list, table, string, number, nothing> {
  let include_path: string = kv get --table=$KV include_path | default ('')
  ^$nu.current-exe --table-mode=none --error-style=plain --no-config-file --include-path=($include_path) --commands=($commands)
  | complete
  | match $in.exit_code {
    _ if not $pipe => ()
    0 => (get $.stdout | from nuon)
    $c => { error make --unspanned {msg: $'subprocess exited with code ($c)' help: $in.stderr} }
  }
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
