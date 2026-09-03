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
#   scripts/dev.sh batch <legislation|jurisprudence|doctrine|auto> <dir> [-j N]
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
  batch <parser|auto> <dir> [-j N]  Parse every file in an arbitrary directory in parallel
                                   (default: one worker per CPU core), using the cached
                                   binaries -- for real-world-sized batches, not the curated
                                   testdata/ fixtures. `auto` sniffs each file's content to
                                   route it to the right parser instead of assuming one type
                                   for the whole directory (see detect_type() below for the
                                   markers used, and its PDF-specific cost note).
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
  scripts/dev.sh batch legislation /path/to/many/acts -j 8
  scripts/dev.sh batch auto /path/to/mixed/corpus
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

# Content-based type sniffing for `batch auto` -- a real-world directory
# won't come pre-sorted into src/testdata/<type>/ folders the way our
# fixtures do, so `auto` mode needs to figure out which parser applies to
# each file on its own.
#
# First version of this only matched our own synthetic .txt fixtures'
# invented labels ("CHAPTER:", "AUTHOR:") and missed all three *real*
# PDFs (verified: `CHAPTER:`/`AUTHOR:` are a convention this project's
# hand-written fixtures use, not something that appears in an actual
# Justice Laws statute or McGill Law Journal PDF). Markers below are
# checked against both the synthetic fixture convention and real
# extracted PDF text (confirmed against all three real fixtures'
# `pdftotext -layout` output directly):
#   - legislation: "CHAPTER:" (fixture) or "Current to " (the exact
#     running-header string strip_running_headers() in
#     legislation_parser.mojo already keys off, i.e. a marker this
#     project already trusts as legislation-specific) or "CONSOLIDATION"
#     (Justice Laws' own bilingual cover-page heading).
#   - jurisprudence: a "[1]"-at-start-of-line paragraph marker (fixture +
#     real, but only once front matter is behind it) or "DOCKET:"/
#     "DOSSIER:"/"CORAM:"/"STYLE OF CAUSE:"/"INTITULÉ:" (real court
#     cover-page fields, present before paragraph [1] even starts).
#   - doctrine: "AUTHOR:"/"AUTEUR:"/"AUTEURE:" (fixture) or "ABSTRACT"/
#     "RÉSUMÉ" (real journal-article convention) or, as a last resort, a
#     "1. " footnote-style line for doctrine pieces using the
#     implicit-title path with none of the above (e.g.
#     src/testdata/doctrine/04_implicit_title_plain_headings.txt) --
#     legislation/jurisprudence numbering never uses "N. " with a period
#     directly after the digit.
# This is a heuristic over real-world formatting, which varies by court/
# publisher -- expect to extend these markers as new document sources
# turn up ones that don't match. For a .txt file this is a cheap direct
# grep. For a .pdf, there's no way to read its text without extracting
# first -- this does a quick, uncropped pdftotext sniff purely to
# classify, then dispatches to the correct parser's *own* extraction
# afterward (which legislation needs anyway, for its two-column crop --
# see read_pdf_text in legislation_parser.mojo). That means a PDF pays
# for extraction twice under `auto`; know that going in for a PDF-heavy
# corpus, and prefer passing a specific parser name (skips sniffing
# entirely) whenever you already know the directory is one type.
detect_type() {
  local f="$1"
  local sniff="$f"
  local tmp=""
  case "$f" in
    *.pdf|*.PDF)
      tmp="$(mktemp)"
      pdftotext -layout -l 5 "$f" "$tmp" 2>/dev/null || true
      sniff="$tmp"
      ;;
  esac

  local type="unknown"
  if grep -qE "CHAPTER:|Current to |CONSOLIDATION" "$sniff" 2>/dev/null; then
    type="legislation"
  elif grep -qE '^\[1\]|DOCKET:|DOSSIER:|CORAM:|STYLE OF CAUSE:|INTITULÉ:' "$sniff" 2>/dev/null; then
    type="jurisprudence"
  elif grep -qE "AUTHOR:|AUTEUR:|AUTEURE:|ABSTRACT|RÉSUMÉ" "$sniff" 2>/dev/null; then
    type="doctrine"
  elif grep -qE '^1\. ' "$sniff" 2>/dev/null; then
    type="doctrine"
  fi

  [[ -n "$tmp" ]] && rm -f "$tmp"
  echo "$type"
}
export -f detect_type

cmd_batch() {
  local parser="${1:-}"
  [[ -z "$parser" ]] && { echo "error: batch requires a parser name (or 'auto') and a directory" >&2; usage; exit 1; }
  shift
  local dir="${1:-}"
  [[ -z "$dir" ]] && { echo "error: batch requires a directory" >&2; exit 1; }
  [[ -d "$dir" ]] || { echo "error: not a directory: $dir" >&2; exit 1; }
  shift

  local jobs
  jobs="$(nproc 2>/dev/null || echo 4)"
  if [[ "${1:-}" == "-j" ]]; then
    jobs="${2:-$jobs}"
  fi

  if [[ "$parser" == "auto" ]]; then
    for p in "${PARSERS[@]}"; do
      pixi run "build-${p}" >/dev/null
    done
  else
    require_parser "$parser"
    pixi run "build-${parser}" >/dev/null
  fi

  local results
  results="$(mktemp)"

  echo "== batch: $parser over $dir (parallel -j$jobs) =="
  local start_ns end_ns
  start_ns=$(date +%s%N)

  find "$dir" -type f | xargs -P "$jobs" -I{} bash -c '
    f="$1"; parser="$2"; results="$3"
    p="$parser"
    if [[ "$p" == "auto" ]]; then
      p="$(detect_type "$f")"
      if [[ "$p" == "unknown" ]]; then
        echo "SKIP $f" >> "$results"
        exit 0
      fi
    fi
    if "bin/${p}_parser" "$f" >/dev/null 2>&1; then
      echo "OK $p $f" >> "$results"
    else
      echo "FAIL $p $f" >> "$results"
    fi
  ' _ {} "$parser" "$results" || true

  end_ns=$(date +%s%N)
  local total_ms=$(( (end_ns - start_ns) / 1000000 ))

  local total passed failed skipped
  total=$(wc -l < "$results" | tr -d ' ')
  passed=$(grep -c '^OK' "$results" || true)
  failed=$(grep -c '^FAIL' "$results" || true)
  skipped=$(grep -c '^SKIP' "$results" || true)

  echo
  echo "$passed/$total parsed successfully (skipped: $skipped)"
  printf 'wall time: %d.%03ds across %d file(s) with %d parallel worker(s)\n' \
    $((total_ms / 1000)) $((total_ms % 1000)) "$total" "$jobs"

  if [[ "$parser" == "auto" ]]; then
    echo "by detected type:"
    for p in "${PARSERS[@]}"; do
      local c
      c=$(grep -cE "^(OK|FAIL) $p " "$results" || true)
      [[ "$c" -gt 0 ]] && echo "  $p: $c"
    done
  fi

  if [[ "$failed" -gt 0 ]]; then
    echo "failed:"
    grep '^FAIL' "$results" | sed 's/^FAIL /  /'
  fi
  if [[ "$skipped" -gt 0 ]]; then
    echo "skipped (type not detected):"
    grep '^SKIP' "$results" | sed 's/^SKIP /  /'
  fi

  rm -f "$results"
  [[ "$failed" -gt 0 ]] && exit 1
  exit 0
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
    batch) cmd_batch "$@" ;;
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
