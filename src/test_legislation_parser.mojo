import legislation_parser
from std.testing import assert_equal, assert_true, assert_raises, TestSuite

# Tests for the PEG grammar and parser in legislation_parser.mojo. Run with:
#   pixi run mojo run src/test_legislation_parser.mojo


def test_basic_section() raises:
    var cur = legislation_parser.Cursor("TITLE: Test Act\n\n1 A simple section.\n")
    var act = cur.parse_act()
    assert_equal(act.title, "Test Act")
    assert_equal(len(act.sections), 1)
    assert_equal(act.sections[0].number, "1")
    assert_equal(act.sections[0].text, "A simple section.")
    assert_equal(len(act.sections[0].subsections), 0)
    assert_equal(len(act.sections[0].paragraphs), 0)


def test_chapter_and_title_meta() raises:
    var cur = legislation_parser.Cursor("CHAPTER: R.S.C., 1985, c. A-1\nTITLE: Access to Information Act\n\n1 Short title.\n")
    var act = cur.parse_act()
    assert_equal(act.chapter, "R.S.C., 1985, c. A-1")
    assert_equal(act.title, "Access to Information Act")


def test_fractional_section_number() raises:
    var cur = legislation_parser.Cursor("TITLE: Test Act\n\n2.1 A fractional section.\n")
    var act = cur.parse_act()
    assert_equal(act.sections[0].number, "2.1")


def test_marginal_note_on_section() raises:
    var cur = legislation_parser.Cursor("TITLE: Test Act\n\nMarginal note: Short title\n1 This Act may be cited as the Test Act.\n")
    var act = cur.parse_act()
    assert_equal(act.sections[0].marginal_note, "Short title")


def test_multiple_headings_before_section() raises:
    # A Part heading immediately followed by another topical heading before
    # the next section -- real statutes stack these (Heading* in the
    # grammar, not just Heading?).
    var text = "TITLE: Test Act\n\nPART II\nMISCELLANEOUS\nMarginal note: Regulations\n3 The Governor in Council may make regulations.\n"
    var cur = legislation_parser.Cursor(text)
    var act = cur.parse_act()
    assert_equal(len(act.sections[0].headings), 2)
    assert_equal(act.sections[0].headings[0], "PART II")
    assert_equal(act.sections[0].headings[1], "MISCELLANEOUS")


def test_subsections_and_paragraphs() raises:
    var text = "TITLE: Test Act\n\n2 (1) The purpose of this Act is\n(a) to do a thing;\n(b) to do another thing.\nMarginal note: For greater certainty\n(2) This section does not limit anything.\n"
    var cur = legislation_parser.Cursor(text)
    var act = cur.parse_act()
    var section = act.sections[0].copy()
    assert_equal(len(section.subsections), 2)
    assert_equal(section.subsections[0].label, "1")
    assert_equal(len(section.subsections[0].paragraphs), 2)
    assert_equal(section.subsections[0].paragraphs[0].label, "a")
    assert_equal(section.subsections[0].paragraphs[1].label, "b")
    assert_equal(section.subsections[1].label, "2")
    assert_equal(section.subsections[1].marginal_note, "For greater certainty")


def test_subparagraphs_and_roman_disambiguation() raises:
    # (a) has subparagraphs (i)(ii); the sibling paragraph (c) that follows
    # must NOT be swallowed as a subparagraph even though 'c' is itself a
    # valid roman-numeral character -- the "(i) must open a sublist" rule.
    var text = "TITLE: Test Act\n\n3 In this Act,\n(a) term one means\n(i) the first meaning, and\n(ii) the second meaning;\n(b) term two means something else;\n(c) term three means a third thing.\n"
    var cur = legislation_parser.Cursor(text)
    var act = cur.parse_act()
    var paragraphs = act.sections[0].paragraphs.copy()
    assert_equal(len(paragraphs), 3)
    assert_equal(paragraphs[0].label, "a")
    assert_equal(len(paragraphs[0].subparagraphs), 2)
    assert_equal(paragraphs[0].subparagraphs[0].label, "i")
    assert_equal(paragraphs[0].subparagraphs[1].label, "ii")
    assert_equal(paragraphs[1].label, "b")
    assert_equal(len(paragraphs[1].subparagraphs), 0)
    assert_equal(paragraphs[2].label, "c")
    assert_equal(len(paragraphs[2].subparagraphs), 0)
    assert_equal(paragraphs[2].text, "term three means a third thing.")


def test_front_matter_is_tolerated_not_rejected() raises:
    # Unlike a hard raise, unparseable leading content (e.g. a real
    # statute PDF's title page and table of contents, which have no
    # `CHAPTER:`/`TITLE:` labels at all) is discarded a line at a time
    # rather than aborting the whole parse -- see the front-matter note on
    # `parse_act`. A document that's *entirely* unparseable front matter
    # legitimately parses to zero sections, not an error.
    var cur = legislation_parser.Cursor("TITLE: Broken Act\n\nBAD SECTION\nnot a number here\n")
    var act = cur.parse_act()
    assert_equal(len(act.sections), 0)
    assert_true(act.front_matter_skipped > 0)


def test_section_number_requires_digit() raises:
    # Direct unit test of the grammar rule's strictness: out of the
    # tolerant top-level harness, `parse_section_number` itself must
    # still reject non-digit content.
    var cur = legislation_parser.Cursor("not a number\n")
    with assert_raises():
        _ = cur.parse_section_number()


def test_french_text_does_not_crash() raises:
    # Regression test: the cursor used to index the source by raw UTF-8
    # byte and crash on multi-byte characters (accès, définitions, ...).
    # Canadian statutes are officially bilingual, so this is a real input,
    # not an edge case.
    var text = "TITLE: Loi sur l'accès à l'information\n\nDÉFINITIONS ET INTERPRÉTATION\nMarginal note: Définitions\n2 Les définitions qui suivent s'appliquent à la présente loi.\n"
    var cur = legislation_parser.Cursor(text)
    var act = cur.parse_act()
    assert_equal(act.title, "Loi sur l'accès à l'information")
    assert_equal(act.sections[0].headings[0], "DÉFINITIONS ET INTERPRÉTATION")
    assert_equal(act.sections[0].marginal_note, "Définitions")


def test_read_document_text_txt_roundtrip() raises:
    var path = "/tmp/claude-1000/-home-kaz-Documents-Projects-trymojo-hello-world/95e3bf32-677f-4743-9a2e-79a687c9d0f7/scratchpad/test_fixture.txt"
    var f = open(path, "w")
    f.write("TITLE: Fixture Act\n\n1 Fixture section.\n")
    f.close()
    var content = legislation_parser.read_document_text(path)
    assert_true(content.startswith("TITLE: Fixture Act"))


def test_read_document_text_unsupported_format_raises() raises:
    with assert_raises():
        _ = legislation_parser.read_document_text("/some/path/act.docx")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
