import doctrine_parser
from std.testing import assert_equal, assert_true, TestSuite

# Integration test against a real, unmodified document -- not a
# hand-written sample. Fixture:
#
#   src/testdata/mlj_readability_deficits.pdf
#   Mike Madden, "Failure to Adapt: Readability Deficits in Canadian
#   Court Decisions Involving Parties with Unique Reading Needs"
#   (2026) 71:2 McGill LJ 605
#   Downloaded directly from the McGill Law Journal's own site
#   (lawjournal.mcgill.ca), an Open Access (CC-BY-ND) article. This is the
#   publicly linked "abstract" PDF (2 pages: English abstract + French
#   résumé), not the full article text -- the journal doesn't post the
#   full text of this piece as a separately downloadable PDF, so this
#   fixture exercises metadata extraction, plain headings, and
#   prose/header-noise handling, but not the numbered-footnote or
#   roman/lettered-heading rules (those are covered against synthetic
#   data in test_doctrine_parser.mojo instead -- see
#   test_footnote_requires_exact_expected_number,
#   test_roman_and_letter_headings, etc.).
#
# Two real findings from testing against this actual document, both
# correct-but-imperfect rather than crashes, and both documented here
# rather than "fixed" into false precision:
#
# 1. The implicit-title fallback (see `maybe_implicit_title` in
#    doctrine_parser.mojo) takes the *first* non-blank line as the title
#    when no "TITLE:" label is present. In this real PDF, that first line
#    is the journal's own running header ("McGill Law Journal — Revue de
#    droit de McGill"), not the article's actual title -- there is no
#    syntactic way to tell a running header from a real title from layout
#    alone once both are flattened to plain text.
# 2. The article's actual title is printed in small-caps type. Small-caps
#    are usually rendered in the underlying PDF as literal capital
#    letters at a smaller point size, and `pdftotext` extracts them as
#    plain, all-uppercase text with spurious spaces where letter-spacing
#    was applied (e.g. "F AILURE TO A DAPT" for "Failure to Adapt"). Each
#    such line has no lowercase letters at all, so `is_all_caps_heading`
#    correctly (if perhaps surprisingly) reads each physical line of the
#    wrapped title as its own separate PlainHeading, rather than one
#    multi-line title -- a faithful parse of what the extracted text
#    actually looks like, not a bug.
#
# Run with:
#   pixi run mojo run src/test_doctrine_integration.mojo


comptime FIXTURE = "src/testdata/mlj_readability_deficits.pdf"


def test_real_mlj_article_parses() raises:
    var content = doctrine_parser.read_document_text(FIXTURE)
    var cur = doctrine_parser.Cursor(content^)
    var pieces = cur.parse_document()
    assert_equal(len(pieces), 1)

    var d = pieces[0].copy()

    # Implicit title: the running header banner, not the real title (see
    # finding 1 above) -- pinned as the current, verified-correct behavior.
    assert_equal(d.meta.get("title", ""), "McGill Law Journal — Revue de droit de McGill")

    var items = d.items.copy()
    assert_equal(len(items), 9)

    # The small-caps title, extracted as four separate all-caps heading
    # lines (see finding 2 above).
    assert_true(items[0].isa[doctrine_parser.Heading]())
    var h0 = items[0][doctrine_parser.Heading].copy()
    assert_equal(h0.marker, "")
    assert_true(h0.text.__contains__("A DAPT"))
    assert_true(items[1].isa[doctrine_parser.Heading]())
    assert_true(items[2].isa[doctrine_parser.Heading]())
    assert_true(items[3].isa[doctrine_parser.Heading]())

    # The author's name, on its own line.
    assert_true(items[4].isa[doctrine_parser.Prose]())
    var author_line = items[4][doctrine_parser.Prose].copy()
    assert_true(author_line.text.__contains__("Mike Madden"))

    # ABSTRACT heading, then the (bilingual-adjacent) English abstract
    # prose -- long enough to have absorbed the page's running
    # header/footer noise as continuation text without corrupting the
    # item boundary.
    var h5 = items[5][doctrine_parser.Heading].copy()
    assert_equal(h5.marker, "")
    assert_equal(h5.text, "ABSTRACT")
    assert_true(items[6].isa[doctrine_parser.Prose]())
    var abstract = items[6][doctrine_parser.Prose].copy()
    assert_true(abstract.text.__contains__("readability"))
    assert_true(abstract.text.byte_length() > 1000)

    # RÉSUMÉ heading (French), then the French résumé prose -- confirms
    # bilingual plain-heading detection and UTF-8 safety against real
    # accented text (études, décisions, québécois-adjacent vocabulary).
    var h8 = items[7][doctrine_parser.Heading].copy()
    assert_equal(h8.marker, "")
    assert_equal(h8.text, "RÉSUMÉ")
    assert_true(items[8].isa[doctrine_parser.Prose]())
    var resume = items[8][doctrine_parser.Prose].copy()
    assert_true(resume.text.__contains__("lisibilité"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
