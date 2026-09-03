import doctrine_parser
from std.testing import assert_equal, assert_true, assert_raises, TestSuite

# Tests for the PEG grammar and parser in doctrine_parser.mojo. Run with:
#   pixi run mojo run src/test_doctrine_parser.mojo


def test_basic_meta_english() raises:
    var text = "TITLE: The Fresh Start Principle\nAUTHOR: J. Smith\nSOURCE: (2024) 12 Can. Bus. L.J. 45\nYEAR: 2024\n\nSome introductory prose.\n"
    var cur = doctrine_parser.Cursor(text)
    var pieces = cur.parse_document()
    assert_equal(len(pieces), 1)
    var d = pieces[0].copy()
    assert_equal(d.meta.get("title", ""), "The Fresh Start Principle")
    assert_equal(d.meta.get("author", ""), "J. Smith")
    assert_equal(d.meta.get("source", ""), "(2024) 12 Can. Bus. L.J. 45")
    assert_equal(d.meta.get("year", ""), "2024")


def test_basic_meta_french() raises:
    # French labels (TITRE/AUTEURE/ANNÉE) map onto the same canonical keys.
    var text = "TITRE: Le principe du nouveau départ\nAUTEURE: M. Tremblay\nSOURCE: (2023) 64 C de D 201\nANNÉE: 2023\n\nProse d'introduction.\n"
    var cur = doctrine_parser.Cursor(text)
    var pieces = cur.parse_document()
    var d = pieces[0].copy()
    assert_equal(d.meta.get("title", ""), "Le principe du nouveau départ")
    assert_equal(d.meta.get("author", ""), "M. Tremblay")
    assert_equal(d.meta.get("year", ""), "2023")


def test_implicit_title_when_no_label() raises:
    # Real journal PDFs print the title as the first line, with no literal
    # "TITLE:" label at all.
    var text = "The Fresh Start Principle in Canadian Bankruptcy Law\n\nSome introductory prose.\n"
    var cur = doctrine_parser.Cursor(text)
    var pieces = cur.parse_document()
    var d = pieces[0].copy()
    assert_equal(d.meta.get("title", ""), "The Fresh Start Principle in Canadian Bankruptcy Law")
    assert_equal(len(d.items), 1)
    assert_true(d.items[0].isa[doctrine_parser.Prose]())


def test_roman_and_letter_headings() raises:
    var text = "TITLE: X\n\nI. Introduction\nSome intro text.\nII. Analysis\nA. First point\nSome analysis.\nB. Second point\nMore analysis.\n"
    var cur = doctrine_parser.Cursor(text)
    var pieces = cur.parse_document()
    var items = pieces[0].items.copy()
    assert_equal(len(items), 7)
    var h0 = items[0][doctrine_parser.Heading].copy()
    assert_equal(h0.marker, "I.")
    assert_equal(h0.level, 1)
    assert_equal(h0.text, "Introduction")
    assert_true(items[1].isa[doctrine_parser.Prose]())
    var h2 = items[2][doctrine_parser.Heading].copy()
    assert_equal(h2.marker, "II.")
    var h3 = items[3][doctrine_parser.Heading].copy()
    assert_equal(h3.marker, "A.")
    assert_equal(h3.level, 2)
    var h5 = items[5][doctrine_parser.Heading].copy()
    assert_equal(h5.marker, "B.")
    assert_equal(h5.level, 2)


def test_plain_heading_no_marker() raises:
    var text = "TITLE: X\n\nABSTRACT\nSome abstract prose.\nCONCLUSION\nSome concluding prose.\n"
    var cur = doctrine_parser.Cursor(text)
    var pieces = cur.parse_document()
    var items = pieces[0].items.copy()
    var h0 = items[0][doctrine_parser.Heading].copy()
    assert_equal(h0.marker, "")
    assert_equal(h0.level, 1)
    assert_equal(h0.text, "ABSTRACT")


def test_sequential_footnotes() raises:
    var text = "TITLE: X\n\nSome prose citing a source.1 And another.2\n\n1. First footnote text.\n2. Second footnote text.\n"
    var cur = doctrine_parser.Cursor(text)
    var pieces = cur.parse_document()
    var items = pieces[0].items.copy()
    assert_equal(len(items), 3)
    assert_true(items[0].isa[doctrine_parser.Prose]())
    var f1 = items[1][doctrine_parser.Footnote].copy()
    assert_equal(f1.number, "1")
    assert_equal(f1.text, "First footnote text.")
    var f2 = items[2][doctrine_parser.Footnote].copy()
    assert_equal(f2.number, "2")


def test_footnote_requires_exact_expected_number() raises:
    # Direct unit test of the grammar rule's strictness: out of the
    # tolerant document-level harness, `parse_footnote` itself must still
    # reject a footnote number that isn't the exact expected next one --
    # this is what stops an in-text numbered list ("1. First point") from
    # being misread as a footnote when a footnote 1 isn't actually
    # expected yet.
    var cur = doctrine_parser.Cursor("5. out of sequence\n")
    with assert_raises():
        _ = cur.parse_footnote(1, "A", 1)


def test_wrapped_prose_is_joined() raises:
    # Real PDFs are often double-spaced, so pdftotext emits each wrapped
    # physical line of one logical paragraph separately, sometimes with a
    # blank line between them. Prose must re-join them with spaces.
    var text = "TITLE: X\n\nThis is a long sentence that\n\nwraps across several physical\n\nlines because the source PDF is double-spaced.\n"
    var cur = doctrine_parser.Cursor(text)
    var pieces = cur.parse_document()
    var p = pieces[0].items[0][doctrine_parser.Prose].copy()
    assert_equal(p.text, "This is a long sentence that wraps across several physical lines because the source PDF is double-spaced.")


def test_multi_document_split() raises:
    # Two doctrine pieces concatenated with no separator: the boundary
    # must be found from the second piece's meta header alone -- a
    # regression test for a bug where Prose (the unconditional fallback in
    # the item grammar, unlike Heading/Footnote which are gated by their
    # own marker) blindly swallowed the next piece's "TITLE:"/"AUTHOR:"
    # lines as if they were its own text.
    var text = "TITLE: First Piece\nAUTHOR: A\n\nSome prose in the first piece that might look like it keeps going on and on.\n\nTITLE: Second Piece\nAUTHOR: B\n\nSome prose in the second piece.\n"
    var cur = doctrine_parser.Cursor(text)
    var pieces = cur.parse_document()
    assert_equal(len(pieces), 2)
    assert_equal(pieces[0].meta.get("title", ""), "First Piece")
    assert_equal(pieces[1].meta.get("title", ""), "Second Piece")
    assert_equal(pieces[1].meta.get("author", ""), "B")
    var p0 = pieces[0].items[0][doctrine_parser.Prose].copy()
    assert_true(not p0.text.__contains__("TITLE"))


def test_heading_does_not_swallow_following_prose() raises:
    # Regression test: a heading must consume only its own line. Doctrine
    # prose has no anchor marker of its own (unlike jurisprudence's
    # "[N]"), so a heading whose text used the same wrapped-line-joining
    # mechanism as its own text would keep merging unmarked prose into
    # itself indefinitely, stopping only when it coincidentally reached
    # text matching the *stale* (not yet advanced) expected letter/roman
    # counters.
    var text = "TITLE: X\n\nI. Introduction\nThe body text of the introduction goes here.\nII. Next Part\nMore text.\n"
    var cur = doctrine_parser.Cursor(text)
    var pieces = cur.parse_document()
    var items = pieces[0].items.copy()
    assert_equal(len(items), 4)
    var h0 = items[0][doctrine_parser.Heading].copy()
    assert_equal(h0.text, "Introduction")
    var p1 = items[1][doctrine_parser.Prose].copy()
    assert_equal(p1.text, "The body text of the introduction goes here.")
    var h2 = items[2][doctrine_parser.Heading].copy()
    assert_equal(h2.marker, "II.")


def test_french_text_does_not_crash() raises:
    # Canadian/Quebec doctrine is bilingual; multi-byte UTF-8 characters
    # (départ, québécois, ...) must not crash the codepoint-indexed cursor.
    var text = "TITRE: Le nouveau départ\nAUTEURE: M. Tremblay\n\nI. Introduction\nLe principe du nouveau départ demeure au coeur du droit québécois.\n"
    var cur = doctrine_parser.Cursor(text)
    var pieces = cur.parse_document()
    assert_equal(pieces[0].meta.get("title", ""), "Le nouveau départ")
    var h0 = pieces[0].items[0][doctrine_parser.Heading].copy()
    assert_equal(h0.text, "Introduction")


def test_empty_document() raises:
    var cur = doctrine_parser.Cursor("")
    var pieces = cur.parse_document()
    assert_equal(len(pieces), 0)


def test_read_document_text_txt_roundtrip() raises:
    var path = "/tmp/claude-1000/-home-kaz-Documents-Projects-trymojo-hello-world/95e3bf32-677f-4743-9a2e-79a687c9d0f7/scratchpad/test_fixture_doctrine.txt"
    var f = open(path, "w")
    f.write("TITLE: Fixture Article\n\nFixture prose.\n")
    f.close()
    var content = doctrine_parser.read_document_text(path)
    assert_true(content.startswith("TITLE: Fixture Article"))


def test_read_document_text_unsupported_format_raises() raises:
    with assert_raises():
        _ = doctrine_parser.read_document_text("/some/path/article.docx")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
