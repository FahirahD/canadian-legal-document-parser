from std.time import perf_counter_ns
import jurisprudence_parser
from std.testing import assert_equal

# See bench_legislation_parser.mojo for why this uses a manual timing loop
# instead of std.benchmark.
#
# Run with:
#   pixi run mojo run src/bench_jurisprudence_parser.mojo


comptime REAL_FIXTURE = "src/testdata/poonian_v_bc_securities_2024scc28.pdf"


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


# Builds a synthetic single judgment with `num_paragraphs` numbered
# paragraphs, each split across several physical lines the way real
# double-spaced court PDFs are, under one roman heading every 20
# paragraphs -- exercises the same TextBlock/lookahead machinery
# (`looking_at_new_item`, `looking_at_heading`) that a real 82-page SCC
# judgment turned up a genuine superlinear blowup in during development
# (see the front-matter/table-of-contents note in jurisprudence_parser.mojo),
# so ns/paragraph here is a meaningful regression signal.
def make_synthetic_judgment(num_paragraphs: Int) -> String:
    var text = String("STYLE OF CAUSE: X v. Y\nCITATION: 2024 SCC 1\n\n")
    var roman = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
    var i = 1
    while i <= num_paragraphs:
        if (i - 1) % 20 == 0:
            var idx = (i - 1) // 20
            if idx < len(roman):
                text += roman[idx] + ". Heading " + String(idx + 1) + "\n"
        var n = String(i)
        text += "[" + n + "] This is the first physical line of paragraph " + n + ", which\n"
        text += "wraps across several physical lines because the source\n"
        text += "document is double-spaced, exactly as real court PDFs are.\n\n"
        i += 1
    return text


def bench_sample_document(iterations: Int) raises:
    var text = String(jurisprudence_parser.SAMPLE_DOCUMENT)
    var input_bytes = text.byte_length()
    var total_judgments = 0
    var start = perf_counter_ns()
    var i = 0
    while i < iterations:
        var cur = jurisprudence_parser.Cursor(text)
        var judgments = cur.parse_document()
        total_judgments += len(judgments)
        i += 1
    var total_ns = perf_counter_ns() - start
    assert_equal(total_judgments, 2 * iterations)
    report("parse_document -- built-in illustrative sample (EN + FR)", iterations, total_ns, input_bytes)


def bench_scaling(num_paragraphs: Int, iterations: Int) raises:
    var text = make_synthetic_judgment(num_paragraphs)
    var input_bytes = text.byte_length()
    var total_paragraphs = 0
    var start = perf_counter_ns()
    var i = 0
    while i < iterations:
        var cur = jurisprudence_parser.Cursor(text)
        var judgments = cur.parse_document()
        for item in judgments[0].items:
            if item.isa[jurisprudence_parser.Paragraph]():
                total_paragraphs += 1
        i += 1
    var total_ns = perf_counter_ns() - start
    assert_equal(total_paragraphs, num_paragraphs * iterations)
    var avg_ns = total_ns // iterations
    var ns_per_paragraph = avg_ns // num_paragraphs
    report(
        "parse_document -- synthetic judgment, " + String(num_paragraphs) + " paragraphs (" + String(ns_per_paragraph) + " ns/paragraph)",
        iterations,
        total_ns,
        input_bytes,
    )


def bench_real_scc_pdf(iterations: Int) raises:
    # PDF extraction (a `pdftotext` subprocess) is a one-time cost, timed
    # and reported separately -- it dominates and isn't representative of
    # in-memory parsing throughput. The parse loop below re-parses the
    # same already-extracted text `iterations` times to isolate that.
    var extract_start = perf_counter_ns()
    var content = jurisprudence_parser.read_document_text(REAL_FIXTURE)
    var extract_ns = perf_counter_ns() - extract_start
    print("pdftotext extraction (one-time): " + format_duration(extract_ns) + " for " + String(content.byte_length()) + " bytes")
    print("")

    var input_bytes = content.byte_length()
    var total_paragraphs = 0
    var start = perf_counter_ns()
    var i = 0
    while i < iterations:
        var cur = jurisprudence_parser.Cursor(content)
        var judgments = cur.parse_document()
        for item in judgments[0].items:
            if item.isa[jurisprudence_parser.Paragraph]():
                total_paragraphs += 1
        i += 1
    var total_ns = perf_counter_ns() - start
    assert_equal(total_paragraphs, 142 * iterations)
    report("parse_document -- real 82-page SCC judgment (Poonian, 2024 SCC 28)", iterations, total_ns, input_bytes)


def main() raises:
    bench_sample_document(500)
    bench_scaling(50, 200)
    bench_scaling(200, 100)
    bench_scaling(800, 25)
    bench_scaling(3200, 10)
    bench_real_scc_pdf(50)
