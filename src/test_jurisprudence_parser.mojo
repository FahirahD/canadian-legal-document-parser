import jurisprudence_parser
from std.testing import assert_equal, assert_true, assert_raises, TestSuite

# Tests for the PEG grammar and parser in jurisprudence_parser.mojo. Run with:
#   pixi run mojo run src/test_jurisprudence_parser.mojo


def test_basic_judgment_english_meta() raises:
    var text = "STYLE OF CAUSE: Her Majesty the Queen v. John Smith\nCITATION: 2021 SCC 5\nCOURT: Supreme Court of Canada\nDOCKET: 38973\nDATE: 2021-02-19\n\n[1] First reason.\n"
    var cur = jurisprudence_parser.Cursor(text)
    var judgments = cur.parse_document()
    assert_equal(len(judgments), 1)
    var j = judgments[0].copy()
    assert_equal(j.meta.get("style_of_cause", ""), "Her Majesty the Queen v. John Smith")
    assert_equal(j.meta.get("citation", ""), "2021 SCC 5")
    assert_equal(j.meta.get("court", ""), "Supreme Court of Canada")
    assert_equal(j.meta.get("docket", ""), "38973")
    assert_equal(j.meta.get("date", ""), "2021-02-19")


def test_basic_judgment_french_meta() raises:
    # French header labels (INTITULÉ/COUR/DOSSIER) map onto the same
    # canonical keys as the English ones.
    var text = "INTITULÉ: Sa Majesté la Reine c. Jean Tremblay\nCITATION: 2020 QCCA 456\nCOUR: Cour d'appel du Québec\nDOSSIER: 500-10-987654-321\nDATE: 2020-11-03\n\n[1] Premier motif.\n"
    var cur = jurisprudence_parser.Cursor(text)
    var judgments = cur.parse_document()
    var j = judgments[0].copy()
    assert_equal(j.meta.get("style_of_cause", ""), "Sa Majesté la Reine c. Jean Tremblay")
    assert_equal(j.meta.get("court", ""), "Cour d'appel du Québec")
    assert_equal(j.meta.get("docket", ""), "500-10-987654-321")


def test_roman_and_letter_headings() raises:
    # Roman headings must run I, II, III, ... in sequence (see the
    # exact-sequence guard tests below), so II. can't be skipped here.
    var text = "STYLE OF CAUSE: X v. Y\n\nI. OVERVIEW\n[1] First paragraph.\nII. FACTS\n[2] Second paragraph.\nIII. ANALYSIS\nA. Standard of Review\n[3] Third paragraph.\n"
    var cur = jurisprudence_parser.Cursor(text)
    var judgments = cur.parse_document()
    var items = judgments[0].items.copy()
    assert_equal(len(items), 7)
    assert_true(items[0].isa[jurisprudence_parser.Heading]())
    var h0 = items[0][jurisprudence_parser.Heading].copy()
    assert_equal(h0.marker, "I.")
    assert_equal(h0.level, 1)
    assert_equal(h0.text, "OVERVIEW")
    assert_true(items[1].isa[jurisprudence_parser.Paragraph]())
    assert_true(items[4].isa[jurisprudence_parser.Heading]())
    var h4 = items[4][jurisprudence_parser.Heading].copy()
    assert_equal(h4.marker, "III.")
    assert_true(items[5].isa[jurisprudence_parser.Heading]())
    var h5 = items[5][jurisprudence_parser.Heading].copy()
    assert_equal(h5.marker, "A.")
    assert_equal(h5.level, 2)


def test_plain_heading_no_marker() raises:
    var text = "STYLE OF CAUSE: X c. Y\n\nMOTIFS\n[1] Bonjour.\nDISPOSITIF\n[2] Le pourvoi est accueilli.\n"
    var cur = jurisprudence_parser.Cursor(text)
    var judgments = cur.parse_document()
    var items = judgments[0].items.copy()
    assert_true(items[0].isa[jurisprudence_parser.Heading]())
    var h0 = items[0][jurisprudence_parser.Heading].copy()
    assert_equal(h0.marker, "")
    assert_equal(h0.level, 1)
    assert_equal(h0.text, "MOTIFS")


def test_multi_judgment_document_split() raises:
    # Two judgments concatenated with no separator: the boundary must be
    # found from the second judgment's meta header alone. This is also a
    # regression test for a bug where a wrapped-text-joining paragraph
    # greedily swallowed the next judgment's "STYLE OF CAUSE:"/"CITATION:"
    # lines as if they were its own continuation text.
    var text = "STYLE OF CAUSE: X v. Y\nCITATION: 2021 SCC 1\n\n[1] First judgment's only paragraph, with enough words that it might look like it keeps going onto more lines of the same reasons.\nSTYLE OF CAUSE: A v. B\nCITATION: 2022 SCC 2\n\n[1] Second judgment's only paragraph.\n"
    var cur = jurisprudence_parser.Cursor(text)
    var judgments = cur.parse_document()
    assert_equal(len(judgments), 2)
    var j0 = judgments[0].copy()
    var j1 = judgments[1].copy()
    assert_equal(j0.meta.get("citation", ""), "2021 SCC 1")
    assert_equal(j1.meta.get("citation", ""), "2022 SCC 2")
    assert_equal(len(j0.items), 1)
    assert_equal(len(j1.items), 1)
    var p0 = j0.items[0][jurisprudence_parser.Paragraph].copy()
    assert_true(not p0.text.__contains__("STYLE OF CAUSE"))


def test_text_block_joins_wrapped_lines() raises:
    # Real court PDFs are double-spaced, so `pdftotext` emits each wrapped
    # physical line of one logical paragraph separately, often with a
    # blank line between them. The parser must re-join them with spaces
    # into one logical paragraph, not treat each physical line as its own
    # unit or leave raw newlines in the text.
    var text = "STYLE OF CAUSE: X v. Y\n\n[1] This is a long paragraph that\n\nwraps across several physical\n\nlines because the source PDF is double-spaced.\n"
    var cur = jurisprudence_parser.Cursor(text)
    var judgments = cur.parse_document()
    var p = judgments[0].items[0][jurisprudence_parser.Paragraph].copy()
    assert_equal(
        p.text,
        "This is a long paragraph that wraps across several physical lines because the source PDF is double-spaced.",
    )


def test_letter_heading_exact_sequence_guard() raises:
    # A wrapped continuation line that happens to start with a capital
    # letter and a period ("D. Nixon, eds., ...") must NOT be misread as a
    # lettered subheading when "D" isn't the expected next letter -- real
    # legal prose is full of author/judge initials shaped exactly like a
    # subheading marker.
    var text = "STYLE OF CAUSE: X v. Y\n\nA. General Principles\n[1] A sentence citing H. Murray and\nD. Nixon, eds., Annual Review 2022, at p. 618.\n"
    var cur = jurisprudence_parser.Cursor(text)
    var judgments = cur.parse_document()
    var items = judgments[0].items.copy()
    assert_equal(len(items), 2)
    var p = items[1][jurisprudence_parser.Paragraph].copy()
    assert_true(p.text.__contains__("D. Nixon"))


def test_roman_heading_exact_sequence_guard() raises:
    # Same guard for RomanHeading: several roman numerals (I, V, X, L, C,
    # D, M) are themselves common leading letters of a citation
    # abbreviation once a line wraps, e.g. "C.B.R. (6th) 263" wrapping
    # right after the "C.". Confirmed against a real 82-page SCC judgment.
    var text = "STYLE OF CAUSE: X v. Y\n\n[1] The earlier proceeding is reported at 86\nC.B.R. (6th) 263, aff'd on appeal.\n"
    var cur = jurisprudence_parser.Cursor(text)
    var judgments = cur.parse_document()
    var items = judgments[0].items.copy()
    assert_equal(len(items), 1)
    var p = items[0][jurisprudence_parser.Paragraph].copy()
    assert_true(p.text.__contains__("C.B.R."))


def test_front_matter_skip_recovers_heading() raises:
    # Real cover pages (title block, coram, table of contents, ...) don't
    # follow any one layout, so everything up to the first exact "[1]" is
    # discarded -- except the one heading-looking line immediately above
    # "[1]", which is the real section heading, not front matter.
    var text = "STYLE OF CAUSE: X v. Y\n\nSUPREME COURT OF CANADA\nBETWEEN:\nSome Party\nAppellant\nI. Introduction\n\n[1] The reasons begin here.\n"
    var cur = jurisprudence_parser.Cursor(text)
    var judgments = cur.parse_document()
    var j = judgments[0].copy()
    assert_true(j.front_matter_skipped > 0)
    var items = j.items.copy()
    assert_true(items[0].isa[jurisprudence_parser.Heading]())
    var h0 = items[0][jurisprudence_parser.Heading].copy()
    assert_equal(h0.marker, "I.")
    assert_equal(h0.text, "Introduction")


def test_paragraph_citation_not_mistaken_for_marker() raises:
    # A citation like "[1995] 3 S.C.R. 453" embedded in paragraph 2's own
    # text must not be mistaken for the start of paragraph 1995 -- the
    # exact-expected-next-number requirement is what disambiguates this.
    var text = "STYLE OF CAUSE: X v. Y\n\n[1] First paragraph.\n[2] As held in Moloney, [1995] 3 S.C.R. 453, at para. 77, the rule applies.\n[3] Third paragraph.\n"
    var cur = jurisprudence_parser.Cursor(text)
    var judgments = cur.parse_document()
    var items = judgments[0].items.copy()
    assert_equal(len(items), 3)
    var p1 = items[1][jurisprudence_parser.Paragraph].copy()
    assert_equal(p1.number, "2")
    assert_true(p1.text.__contains__("[1995] 3 S.C.R. 453"))
    var p2 = items[2][jurisprudence_parser.Paragraph].copy()
    assert_equal(p2.number, "3")


def test_front_matter_is_tolerated_not_rejected() raises:
    # Unlike legislation_parser.mojo (which fails loudly on the first
    # unrecognized line), a leading line that matches neither a meta label
    # nor "[1]" is legitimately front matter under this grammar, not an
    # error -- real cover pages guarantee such lines exist.
    var cur = jurisprudence_parser.Cursor("this is not a valid header at all\n[1] text\n")
    var judgments = cur.parse_document()
    assert_equal(len(judgments), 1)
    assert_equal(judgments[0].front_matter_skipped, 1)


def test_paragraph_requires_exact_expected_number() raises:
    # Direct unit test of the grammar rule's strictness: out of the
    # tolerant document-level harness, `parse_paragraph` itself must still
    # reject a paragraph number that isn't the exact expected next one.
    var cur = jurisprudence_parser.Cursor("[5] out of sequence\n")
    with assert_raises():
        _ = cur.parse_paragraph(1, "A", 1)


def test_empty_document() raises:
    var cur = jurisprudence_parser.Cursor("")
    var judgments = cur.parse_document()
    assert_equal(len(judgments), 0)


def test_read_document_text_txt_roundtrip() raises:
    var path = "/tmp/claude-1000/-home-kaz-Documents-Projects-trymojo-hello-world/95e3bf32-677f-4743-9a2e-79a687c9d0f7/scratchpad/test_fixture_judgment.txt"
    var f = open(path, "w")
    f.write("STYLE OF CAUSE: X v. Y\n\n[1] Fixture paragraph.\n")
    f.close()
    var content = jurisprudence_parser.read_document_text(path)
    assert_true(content.startswith("STYLE OF CAUSE: X v. Y"))


def test_read_document_text_unsupported_format_raises() raises:
    with assert_raises():
        _ = jurisprudence_parser.read_document_text("/some/path/judgment.docx")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
