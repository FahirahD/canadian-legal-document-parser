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
  list                            List the underlying pixi tasks this script wraps

Examples:
  scripts/dev.sh parse doctrine src/testdata/mlj_readability_deficits.pdf
  scripts/dev.sh test unit doctrine
  scripts/dev.sh test integration
  scripts/dev.sh test all
  scripts/dev.sh bench legislation
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
