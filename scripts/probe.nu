#!/usr/bin/env /usr/bin/nu --no-config-file

const ROLES: list<string> = [
  test
  ignore
  before-each
  after-each
  before-all
  after-all
]

def main []: nothing -> table<name: string, role: string, ignore: bool> {
  scope commands
  | where type == custom
  | par-each --keep-order {|c|
    select $.name $.description $.attributes.name?
    | rename --column={attributes.name: attrs}
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
