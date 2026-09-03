from std.time import perf_counter_ns
import legislation_parser
from std.testing import assert_equal

# Manual timing harness rather than std.benchmark: this Mojo build's
# `Bencher.bench_function` requires the benched function to be a genuine
# "capturing" closure type, and a plain top-level/nested `def` (even with
# an explicit `{}` capture list) doesn't satisfy that -- fighting the
# closure-type system isn't worth it for what is otherwise a simple
# "time N iterations" loop. `perf_counter_ns` plus a manual loop is
# standard practice and keeps this file dependency-free.
#
# Run with:
#   pixi run mojo run src/bench_legislation_parser.mojo


def format_duration(ns: Int) -> String:
    if ns < 1_000:
        return String(ns) + " ns"
    if ns < 1_000_000:
        return String(Float64(ns) / 1_000.0) + " us"
    if ns < 1_000_000_000:
        return String(Float64(ns) / 1_000_000.0) + " ms"
    return String(Float64(ns) / 1_000_000_000.0) + " s"


def report(name: String, iterations: Int, total_ns: Int, input_bytes: Int):
    var avg_ns = total_ns // iterations
    print(name)
    print("  iterations: " + String(iterations))
    print("  total:      " + format_duration(total_ns))
    print("  avg/iter:   " + format_duration(avg_ns))
    if input_bytes > 0 and avg_ns > 0:
        var mb_per_s = (Float64(input_bytes) / 1_000_000.0) / (Float64(avg_ns) / 1_000_000_000.0)
        print("  throughput: " + String(mb_per_s) + " MB/s (" + String(input_bytes) + " bytes/iter)")
    print("")


# Builds a synthetic act with `num_sections` sections, each with two
# paragraphs, to probe how parse time scales with input size -- this
# grammar is hand-rolled recursive-descent PEG with backtracking
# (checkpoint/reset, nested lookahead), and jurisprudence_parser.mojo's
# development turned up a real superlinear-lookahead blowup in exactly
# this kind of repeated-structure input, so tracking ns/section here is a
# meaningful regression signal, not just a vanity number.
def make_synthetic_act(num_sections: Int) -> String:
    var text = String("TITLE: Synthetic Benchmark Act\n\n")
    var i = 1
    while i <= num_sections:
        var n = String(i)
        text += n + " This is section number " + n + " of the synthetic benchmark act, containing representative section-level text of realistic length.\n"
        text += "(a) the first paragraph of section " + n + ";\n"
        text += "(b) the second paragraph of section " + n + ".\n\n"
        i += 1
    return text


def bench_sample_act(iterations: Int) raises:
    var text = String(legislation_parser.SAMPLE_ACT)
    var input_bytes = text.byte_length()
    var total_sections = 0
    var start = perf_counter_ns()
    var i = 0
    while i < iterations:
        var cur = legislation_parser.Cursor(text)
        var act = cur.parse_act()
        total_sections += len(act.sections)
        i += 1
    var total_ns = perf_counter_ns() - start
    assert_equal(total_sections, 3 * iterations)
    report("parse_act -- built-in illustrative sample", iterations, total_ns, input_bytes)


def bench_scaling(num_sections: Int, iterations: Int) raises:
    var text = make_synthetic_act(num_sections)
    var input_bytes = text.byte_length()
    var total_sections = 0
    var start = perf_counter_ns()
    var i = 0
    while i < iterations:
        var cur = legislation_parser.Cursor(text)
        var act = cur.parse_act()
        total_sections += len(act.sections)
        i += 1
    var total_ns = perf_counter_ns() - start
    assert_equal(total_sections, num_sections * iterations)
    var avg_ns = total_ns // iterations
    var ns_per_section = avg_ns // num_sections
    report(
        "parse_act -- synthetic act, " + String(num_sections) + " sections (" + String(ns_per_section) + " ns/section)",
        iterations,
        total_ns,
        input_bytes,
    )


def main() raises:
    bench_sample_act(500)
    bench_scaling(50, 200)
    bench_scaling(200, 100)
    bench_scaling(800, 25)
    bench_scaling(3200, 10)
