from std.time import perf_counter_ns
import doctrine_parser
from std.testing import assert_equal

# Manual timing harness rather than std.benchmark -- see
# bench_legislation_parser.mojo / bench_jurisprudence_parser.mojo for why:
# this Mojo build's `Bencher.bench_function` requires the benched function
# to be a genuine "capturing" closure type, which neither a top-level nor
# a `{}`-annotated nested `def` satisfies here.
#
# Run with:
#   pixi run mojo run src/bench_doctrine_parser.mojo


comptime REAL_FIXTURE = "src/testdata/mlj_readability_deficits.pdf"


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


# Builds a synthetic single doctrine piece with `num_footnotes` sequential
# footnotes, each preceded by a short prose block referencing it, under
# one roman heading every 10 footnotes -- exercises the same
# TextBlock/lookahead machinery (`looking_at_new_item`, `looking_at_heading`)
# that turned up two real bugs during development (a heading swallowing
# all following unmarked prose, and Prose blindly consuming the next
# concatenated document's meta header), so ns/footnote here is a
# meaningful regression signal for both correctness and performance.
def make_synthetic_doctrine(num_footnotes: Int) -> String:
    var text = String("TITLE: Synthetic Benchmark Article\nAUTHOR: Bench Author\n\n")
    var roman = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
    var i = 1
    while i <= num_footnotes:
        if (i - 1) % 10 == 0:
            var idx = (i - 1) // 10
            if idx < len(roman):
                text += roman[idx] + ". Heading " + String(idx + 1) + "\n"
        var n = String(i)
        text += "Some representative prose discussing a point and citing a\n"
        text += "source that wraps across several physical lines, ending\n"
        text += "with a reference to the point being made." + n + "\n\n"
        i += 1
    text += "\n"
    i = 1
    while i <= num_footnotes:
        var n = String(i)
        text += n + ". Footnote text for reference " + n + ", citing a case or\n"
        text += "a secondary source at some length.\n"
        i += 1
    return text


def bench_sample_document(iterations: Int) raises:
    var text = String(doctrine_parser.SAMPLE_DOCUMENT)
    var input_bytes = text.byte_length()
    var total_pieces = 0
    var start = perf_counter_ns()
    var i = 0
    while i < iterations:
        var cur = doctrine_parser.Cursor(text)
        var pieces = cur.parse_document()
        total_pieces += len(pieces)
        i += 1
    var total_ns = perf_counter_ns() - start
    assert_equal(total_pieces, 2 * iterations)
    report("parse_document -- built-in illustrative sample (EN + FR)", iterations, total_ns, input_bytes)


def bench_scaling(num_footnotes: Int, iterations: Int) raises:
    var text = make_synthetic_doctrine(num_footnotes)
    var input_bytes = text.byte_length()
    var total_footnotes = 0
    var start = perf_counter_ns()
    var i = 0
    while i < iterations:
        var cur = doctrine_parser.Cursor(text)
        var pieces = cur.parse_document()
        for item in pieces[0].items:
            if item.isa[doctrine_parser.Footnote]():
                total_footnotes += 1
        i += 1
    var total_ns = perf_counter_ns() - start
    assert_equal(total_footnotes, num_footnotes * iterations)
    var avg_ns = total_ns // iterations
    var ns_per_footnote = avg_ns // num_footnotes
    report(
        "parse_document -- synthetic article, " + String(num_footnotes) + " footnotes (" + String(ns_per_footnote) + " ns/footnote)",
        iterations,
        total_ns,
        input_bytes,
    )


def bench_real_mlj_pdf(iterations: Int) raises:
    # PDF extraction (a `pdftotext` subprocess) is a one-time cost, timed
    # and reported separately -- it dominates and isn't representative of
    # in-memory parsing throughput. The parse loop below re-parses the
    # same already-extracted text `iterations` times to isolate that.
    var extract_start = perf_counter_ns()
    var content = doctrine_parser.read_document_text(REAL_FIXTURE)
    var extract_ns = perf_counter_ns() - extract_start
    print("pdftotext extraction (one-time): " + format_duration(extract_ns) + " for " + String(content.byte_length()) + " bytes")
    print("")

    var input_bytes = content.byte_length()
    var total_items = 0
    var start = perf_counter_ns()
    var i = 0
    while i < iterations:
        var cur = doctrine_parser.Cursor(content)
        var pieces = cur.parse_document()
        total_items += len(pieces[0].items)
        i += 1
    var total_ns = perf_counter_ns() - start
    assert_equal(total_items, 9 * iterations)
    report("parse_document -- real McGill Law Journal article abstract (Madden, 2026)", iterations, total_ns, input_bytes)


def main() raises:
    bench_sample_document(500)
    bench_scaling(50, 200)
    bench_scaling(200, 100)
    bench_scaling(800, 25)
    bench_scaling(3200, 10)
    bench_real_mlj_pdf(200)
