#!/usr/bin/env bash
# Convenience runner for this project's parse/test/bench tasks.
#
# Works the same whether it's launched from a plain terminal or from
# VS Code (see .vscode/tasks.json, which just calls this script).
#
# Usage:
#   scripts/dev.sh build [legislation|jurisprudence|doctrine]
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
  build [parser]                  Compile parser + benchmark binaries into bin/ (gitignored);
                                   omit parser to build all three. parse/bench/smoke below
                                   trigger this automatically and skip it once bin/ is current
                                   (see pixi.toml's build-* task inputs/outputs)
  parse <parser> [file...]        Run a parser (legislation | jurisprudence | doctrine)
  test [scope] [parser]           Run tests. scope: unit (default) | integration | all
                                   parser is optional; omit to run all three parsers
  bench [parser]                  Run benchmarks; omit parser to run all three
  smoke [parser]                  Parse every file in src/testdata/<parser>/ and report
                                   pass/fail + timing per file; omit parser to check all three
  list                            List the underlying pixi tasks this script wraps

Examples:
  scripts/dev.sh build
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

cmd_build() {
  local parser="${1:-}"
  if [[ -n "$parser" ]]; then
    require_parser "$parser"
    pixi run "build-${parser}"
    pixi run "build-bench-${parser}"
  else
    pixi run build
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
  local parsers_to_run=("${PARSERS[@]}")
  if [[ -n "$parser" ]]; then
    require_parser "$parser"
    parsers_to_run=("$parser")
  fi

  # Each bench-<parser> run already prints its own "TOTAL: N benchmark(s),
  # <duration> wall time" line (in-process, so it excludes mojo's
  # compile/startup cost -- see run_smoke() in the parsers for the same
  # reasoning). When running more than one parser here, also report a
  # shell-level grand total across all of them, which *does* include that
  # per-invocation compile/startup cost, since that's the real wall time
  # of running `scripts/dev.sh bench`.
  local grand_start grand_ms
  grand_start=$(date +%s%N)

  for p in "${parsers_to_run[@]}"; do
    echo "== bench: $p =="
    pixi run "bench-${p}"
    echo
  done

  if [[ ${#parsers_to_run[@]} -gt 1 ]]; then
    grand_ms=$(( ($(date +%s%N) - grand_start) / 1000000 ))
    printf 'GRAND TOTAL: %d parser(s) benchmarked, %d.%03ds wall time (includes mojo compile/startup per parser)\n' \
      "${#parsers_to_run[@]}" $((grand_ms / 1000)) $((grand_ms % 1000))
  fi
}

cmd_smoke() {
  local parser="${1:-}"
  local parsers_to_run=("${PARSERS[@]}")
  if [[ -n "$parser" ]]; then
    require_parser "$parser"
    parsers_to_run=("$parser")
  fi

  # Each parser's own `--smoke <dir>` mode (see run_smoke() in the parser
  # .mojo files) loops over the folder and times each file with
  # perf_counter_ns *inside* one already-running process, so the reported
  # per-file times are real read+parse cost, not `mojo run`'s per-invocation
  # compile/startup overhead (which used to dominate when this shelled out
  # to `pixi run parse-<parser> <file>` once per file).
  local failed=0
  for p in "${parsers_to_run[@]}"; do
    local dir="src/testdata/$p"
    if [[ ! -d "$dir" ]]; then
      echo "warning: no fixtures directory for '$p' ($dir)" >&2
      continue
    fi
    pixi run "smoke-${p}" || failed=1
  done

  exit "$failed"
}

cmd_list() {
  pixi task list
}

main() {
  local command="${1:-}"
  [[ -z "$command" ]] && { usage; exit 1; }
  shift

  case "$command" in
    build) cmd_build "$@" ;;
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
