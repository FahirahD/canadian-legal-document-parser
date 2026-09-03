import jurisprudence_parser
from std.os import listdir
from std.testing import assert_equal, assert_true, TestSuite

# Integration test against a real, unmodified court filing -- not a
# hand-written sample. Fixture:
#
#   src/testdata/jurisprudence/poonian_v_bc_securities_2024scc28.pdf
#   Poonian v. British Columbia (Securities Commission), 2024 SCC 28
#   Downloaded from the Supreme Court of Canada's own decisions site
#   (decisions.scc-csc.ca), 82 pages, majority + partial dissent.
#
# This exact document is what drove most of the real fixes in
# jurisprudence_parser.mojo: the \f page-break normalization, front-matter
# skipping past a 400+ line cover page and table of contents, wrapped-line
# joining for double-spaced reasons, and the exact-expected-sequence
# guards on paragraph numbers, letter headings and roman headings (without
# which "D. B. Nixon, eds., ...", "C.B.R. (6th) 263, ..." and similar
# citation/initial text that happens to wrap to the start of a line get
# misread as bogus headings). The assertions below are ground truth taken
# directly from a verified-correct run against this fixture, cross-checked
# against facts stated in the judgment itself (e.g. its own cover page
# says the dissent runs from paragraph 117 to 142).
#
# Run with:
#   pixi run mojo run src/test_jurisprudence_integration.mojo


comptime FIXTURE = "src/testdata/jurisprudence/poonian_v_bc_securities_2024scc28.pdf"
comptime FIXTURES_DIR = "src/testdata/jurisprudence"


def test_real_scc_judgment_parses() raises:
    var content = jurisprudence_parser.read_document_text(FIXTURE)
    var cur = jurisprudence_parser.Cursor(content^)
    var judgments = cur.parse_document()
    assert_equal(len(judgments), 1)

    var j = judgments[0].copy()

    # A real cover page (title block, coram, table of contents, ...) has
    # no consistent layout across courts, so almost none of it matches a
    # recognized meta label -- it's discarded as front matter instead.
    # This is a real ~400-line cover page + table of contents, not a
    # trivial amount of front matter.
    assert_true(j.front_matter_skipped > 300)

    var items = j.items.copy()

    # Collect headings and paragraph numbers in document order.
    var heading_markers: List[String] = []
    var heading_texts: List[String] = []
    var paragraph_numbers: List[String] = []
    for item in items:
        if item.isa[jurisprudence_parser.Heading]():
            var h = item[jurisprudence_parser.Heading].copy()
            heading_markers.append(h.marker)
            heading_texts.append(h.text)
        else:
            var p = item[jurisprudence_parser.Paragraph].copy()
            paragraph_numbers.append(p.number)

    # Every top-level roman heading from the table of contents, in order,
    # plus the four lettered subheadings and the dissent's unmarked
    # judge-name heading ("KARAKATSANIS J. --" has no numbering at all).
    assert_equal(len(heading_markers), 11)
    assert_equal(heading_markers[0], "I.")
    assert_equal(heading_texts[0], "Introduction")
    assert_equal(heading_markers[1], "II.")
    assert_equal(heading_texts[1], "Facts")
    assert_equal(heading_markers[2], "III.")
    assert_equal(heading_markers[3], "A.")
    assert_equal(heading_markers[4], "B.")
    assert_equal(heading_markers[5], "IV.")
    assert_equal(heading_markers[6], "V.")
    assert_equal(heading_markers[7], "A.")
    assert_equal(heading_markers[8], "B.")
    assert_equal(heading_markers[9], "VI.")
    assert_equal(heading_texts[9], "Conclusion")
    assert_equal(heading_markers[10], "")
    assert_equal(heading_texts[10], "KARAKATSANIS J. —")

    # 142 sequential numbered paragraphs, majority (1-116) plus dissent
    # (117-142) -- matches the "(paras. 117 to 142)" note on the
    # judgment's own cover page.
    assert_equal(len(paragraph_numbers), 142)
    assert_equal(paragraph_numbers[0], "1")
    assert_equal(paragraph_numbers[115], "116")
    assert_equal(paragraph_numbers[116], "117")
    assert_equal(paragraph_numbers[141], "142")

    # Regression guard: none of the citation/initial abbreviations that
    # used to be misread as bogus headings ("D. B. Nixon, eds., ...",
    # "C.B.R. (6th) 263, ...", "J. Sarra, Bankruptcy ...", "S. C.J.), at
    # para. 71") should appear as a heading marker+text pair -- they must
    # have been absorbed as paragraph continuation text instead.
    for text in heading_texts:
        assert_true(not text.__contains__("Nixon"))
        assert_true(not text.__contains__("C.B.R."))
        assert_true(not text.__contains__("Sarra"))


# Folder-level smoke coverage, distinct from the single-fixture ground-truth
# assertions above: every file in src/testdata/jurisprudence/ (the real SCC
# judgment PDF plus the hand-written .txt fixtures exercising individual
# grammar features -- lettered subheadings, front-matter-heavy cover pages,
# concatenated judgments, bilingual text, ...) must parse without raising.
# Add a new fixture to that folder and it is covered here automatically.
def test_all_testdata_fixtures_parse() raises:
    var failures: List[String] = []
    for name in listdir(FIXTURES_DIR):
        var path = FIXTURES_DIR + "/" + name
        try:
            var content = jurisprudence_parser.read_document_text(path)
            var cur = jurisprudence_parser.Cursor(content^)
            _ = cur.parse_document()
        except e:
            failures.append(name + ": " + String(e))
    assert_true(len(failures) == 0, "fixtures failed to parse: " + String(failures))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
