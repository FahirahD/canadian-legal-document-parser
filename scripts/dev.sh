#!/usr/bin/env bash
# Convenience runner for this project's parse/test/bench tasks.
#
# Works the same whether it's launched from a plain terminal or from
# VS Code (see .vscode/tasks.json, which just calls this script).
#
# Usage:
#   scripts/dev.sh parse <legislation|jurisprudence|doctrine> [file...]
#   scripts/dev.sh test [unit|integration|all] [legislation|jurisprudence|doctrine]
#   scripts/dev.sh bench [legislation|jurisprudence|doctrine]
#   scripts/dev.sh smoke [legislation|jurisprudence|doctrine]
#   scripts/dev.sh list
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PARSERS=(legislation jurisprudence doctrine)

usage() {
  cat <<'EOF'
Usage: scripts/dev.sh <command> [args]

Commands:
  parse <parser> [file...]        Run a parser (legislation | jurisprudence | doctrine)
  test [scope] [parser]           Run tests. scope: unit (default) | integration | all
                                   parser is optional; omit to run all three parsers
  bench [parser]                  Run benchmarks; omit parser to run all three
  smoke [parser]                  Parse every file in src/testdata/<parser>/ and report
                                   pass/fail per file; omit parser to check all three
  list                            List the underlying pixi tasks this script wraps

Examples:
  scripts/dev.sh parse doctrine src/testdata/doctrine/01_basic_footnotes.txt
  scripts/dev.sh test unit doctrine
  scripts/dev.sh test integration
  scripts/dev.sh test all
  scripts/dev.sh bench legislation
  scripts/dev.sh smoke
  scripts/dev.sh smoke jurisprudence
EOF
}

is_parser() {
  local p="$1"
  for known in "${PARSERS[@]}"; do
    [[ "$p" == "$known" ]] && return 0
  done
  return 1
}

require_parser() {
  local p="$1"
  if ! is_parser "$p"; then
    echo "error: unknown parser '$p' (expected one of: ${PARSERS[*]})" >&2
    exit 1
  fi
}

cmd_parse() {
  local parser="${1:-}"
  [[ -z "$parser" ]] && { echo "error: parse requires a parser name" >&2; usage; exit 1; }
  require_parser "$parser"
  shift
  pixi run "parse-${parser}" "$@"
}

cmd_test() {
  local scope="${1:-unit}"
  local parser="${2:-}"

  case "$scope" in
    unit|integration)
      if [[ -n "$parser" ]]; then
        require_parser "$parser"
        pixi run "test-${parser}$( [[ "$scope" == "integration" ]] && echo "-integration" )"
      else
        pixi run "test$( [[ "$scope" == "integration" ]] && echo "-integration" )"
      fi
      ;;
    all)
      if [[ -n "$parser" ]]; then
        require_parser "$parser"
        pixi run "test-${parser}"
        pixi run "test-${parser}-integration"
      else
        pixi run test-all
      fi
      ;;
    *)
      echo "error: unknown test scope '$scope' (expected: unit | integration | all)" >&2
      exit 1
      ;;
  esac
}

cmd_bench() {
  local parser="${1:-}"
  if [[ -n "$parser" ]]; then
    require_parser "$parser"
    pixi run "bench-${parser}"
  else
    pixi run bench
  fi
}

cmd_smoke() {
  local parser="${1:-}"
  local parsers_to_run=("${PARSERS[@]}")
  if [[ -n "$parser" ]]; then
    require_parser "$parser"
    parsers_to_run=("$parser")
  fi

  local tmp
  tmp="$(mktemp)"

  local total=0
  local passed=0
  local failures=()

  for p in "${parsers_to_run[@]}"; do
    local dir="src/testdata/$p"
    if [[ ! -d "$dir" ]]; then
      echo "warning: no fixtures directory for '$p' ($dir)" >&2
      continue
    fi
    echo "== $p =="
    for f in "$dir"/*; do
      [[ -f "$f" ]] || continue
      total=$((total + 1))
      if pixi run "parse-${p}" "$f" >"$tmp" 2>&1; then
        echo "  OK    $f"
        passed=$((passed + 1))
      else
        echo "  FAIL  $f"
        failures+=("$f")
        sed 's/^/        /' "$tmp"
      fi
    done
  done

  rm -f "$tmp"

  echo
  echo "$passed/$total fixtures parsed successfully"
  if [[ ${#failures[@]} -gt 0 ]]; then
    echo "failed:"
    printf '  %s\n' "${failures[@]}"
    exit 1
  fi
}

cmd_list() {
  pixi task list
}

main() {
  local command="${1:-}"
  [[ -z "$command" ]] && { usage; exit 1; }
  shift

  case "$command" in
    parse) cmd_parse "$@" ;;
    test) cmd_test "$@" ;;
    bench) cmd_bench "$@" ;;
    smoke) cmd_smoke "$@" ;;
    list) cmd_list ;;
    -h|--help|help) usage ;;
    *)
      echo "error: unknown command '$command'" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
