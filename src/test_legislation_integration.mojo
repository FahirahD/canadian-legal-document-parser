import legislation_parser
from std.testing import assert_equal, assert_true, TestSuite

# Integration test against a real, unmodified statute PDF -- not a
# hand-written sample. Fixture:
#
#   src/testdata/access_to_information_act.pdf
#   Access to Information Act, R.S.C., 1985, c. A-1 (current consolidation)
#   Downloaded directly from laws-lois.justice.gc.ca, 118 pages.
#
# This document drove a real, substantial round of fixes to
# legislation_parser.mojo, each confirmed against this exact PDF (not
# hypothetical):
#
#   1. Justice Laws' consolidated PDFs lay English and French out as two
#      side-by-side columns on every page; `pdftotext -layout` alone reads
#      left-to-right across both, interleaving the languages onto the same
#      lines. Fixed by cropping to the left half of the page
#      (`pdftotext -x 0 -W <half width>`), which isolates the English
#      column.
#   2. Marginal notes have no literal "Marginal note:" label in real PDF
#      text (that only exists as HTML screen-reader markup) -- just an
#      unlabeled Title Case line, sometimes two, directly above a
#      provision. `looks_like_heading` was loosened from "all caps" to
#      "starts with an uppercase letter, isn't itself a clause marker or
#      the labeled form", folding both real headings and informal notes
#      into `Section.headings` (a deliberate simplification: it loses the
#      distinction between "this is a group heading" and "this is this
#      provision's own note" for real PDFs, but loses no actual text).
#   3. Paragraph/subsection/subparagraph markers are indented with leading
#      spaces in real PDFs; the grammar rules for them now tolerate
#      leading whitespace.
#   4. Clause text wraps across physical lines with no blank line inside
#      one clause (unlike jurisprudence_parser.mojo's double-spaced
#      judgments); `parse_text_block` joins wrapped lines, stopping at a
#      blank line or the start of a new marker/heading/note.
#   5. Running headers/footers ("Current to ...", "Last amended on ...", a
#      repeated "Sections X-Y" banner) are stripped during PDF extraction.
#   6. A section number is only accepted when followed by a space and then
#      an uppercase letter or "(" -- rejecting two real false-positive
#      shapes found in this exact document: a trailing amendment-history
#      citation right after a clause's own text ("1980-81-82-83, c. 111,
#      Sch. I ..." -- digits followed by "-", not a space) and an in-text
#      cross-reference wrapping to the start of a line ("...under section
#      41 or 44 is to be heard..." -- "41" followed by a space, but then a
#      lowercase word continuing the sentence it's embedded in, not a
#      fresh capitalized clause).
#   7. The real front matter (title page, notices, and a table of contents
#      that itself mirrors the *entire* real section sequence closely
#      enough to parse as ~150 well-formed but bogus sections) and the
#      trailing "Amendments Not in Force"/Schedules material (with its own
#      unrelated, non-monotonic numbering) are handled by one rule in two
#      states: restarting at exactly section 1 discards everything
#      accumulated so far (the table of contents); once real content has
#      been found that way, any later non-increasing jump means the real
#      body has *ended* -- stop and keep what was parsed, rather than
#      discarding ~100 correctly-parsed real sections for appendix noise.
#
# The assertions below are ground truth taken directly from a
# verified-correct run against this fixture.
#
# Run with:
#   pixi run mojo run src/test_legislation_integration.mojo


comptime FIXTURE = "src/testdata/access_to_information_act.pdf"


def test_real_act_pdf_parses() raises:
    var content = legislation_parser.read_document_text(FIXTURE)
    var cur = legislation_parser.Cursor(content^)
    var act = cur.parse_act()

    # Real published PDFs have no "CHAPTER:"/"TITLE:" labels (that's the
    # hand-written sample's own convention) -- chapter/title are best-
    # effort only and legitimately empty here.
    assert_equal(act.chapter, "")
    assert_equal(act.title, "")

    # A real cover page, official-status notices, and a ~150-entry table
    # of contents mirroring the whole Act -- discarded as front matter.
    assert_true(act.front_matter_skipped > 500)

    # 155 Section entries: 101 whole numbered sections (1-101, with a few
    # repealed/renumbered gaps) plus every fractional insertion (3.01,
    # 3.1, 3.2, 6.1, 16.1-16.6, ...) counted as its own Section.
    assert_equal(len(act.sections), 155)

    var first = act.sections[0].copy()
    assert_equal(first.number, "1")
    assert_equal(first.headings[0], "Short Title")
    assert_equal(first.headings[1], "Short title")
    assert_true(first.text.startswith("This Act may be cited as the Access to Information Act."))

    var last = act.sections[len(act.sections) - 1].copy()
    assert_equal(last.number, "101")
    assert_equal(last.headings[0], "Regulations")
    assert_equal(len(last.subsections), 1)

    # Regression guard: the real trailing "Amendments Not in Force"/
    # Schedules appendix (confirmed present in this exact PDF, with its
    # own unrelated numbering starting well below 101) must not have
    # corrupted the real section list.
    for s in act.sections:
        assert_true(not s.text.__contains__("Stablecoin Act"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
