from std.sys import argv
from std.utils import Variant
from std.python import Python

# =============================================================================
# A PEG grammar for Canadian (and Quebec) case-law ("jurisprudence") document
# structure.
#
# Judgments published by Canadian courts -- English-language courts across
# the country and French-language ones in Quebec alike -- follow a shared
# structural convention that is distinct from statute drafting: paragraphs
# are numbered in square brackets ("[1]", "[2]", ...), not with the
# "(1)(a)(i)" nesting used in legislation (see legislation_parser.mojo), and
# headings use roman numerals ("I.", "II."), lettered subheadings ("A.",
# "B."), or plain all-caps titles ("MOTIFS", "DISPOSITIF") with no numbering
# at all -- common in Quebec judgments. This grammar is bilingual: it accepts
# both the English and French header labels a real filing would use.
#
#   Document       <- Judgment+
#   Judgment       <- MetaLine* FrontMatter Item*
#   MetaLine       <- MetaLabel WS TextToEOL
#   MetaLabel      <- "STYLE OF CAUSE:" / "INTITULÉ:" / "CITATION:"
#                    / "COURT:" / "COUR:" / "DOCKET:" / "DOSSIER:" / "DATE:"
#   FrontMatter    <- (!Paragraph(1) Line)*                 # see note below
#   Item           <- Heading / Paragraph(n)
#   Heading        <- RomanHeading / LetterHeading / PlainHeading
#   RomanHeading(r) <- Roman(r) "." WS TextBlock(n)          # "I. OVERVIEW", r = expected next roman numeral
#   LetterHeading(l) <- l "." WS TextBlock(n)                # "A. Background", l = expected next letter
#   PlainHeading   <- UpperLine                              # "MOTIFS"
#   Paragraph(n)   <- "[" n "]" WS TextBlock(n+1)            # "[1] ...", n = expected next number
#   TextBlock(n)   <- TextToEOL (!(Paragraph(n) / Heading) TextToEOL)*
#   UpperLine      <- (!Lower .)+ NEWLINE
#   TextToEOL      <- (!NEWLINE .)* NEWLINE?
#   WS             <- ' '*
#
# `Judgment`'s `Item*` is unbounded ordered choice with backtracking: the
# body loop keeps consuming headings/paragraphs and simply *stops* (without
# erroring) the moment a line matches neither -- which is exactly how the
# top-level `Document <- Judgment+` tells two consecutive judgments apart
# when several are concatenated in one file, with no explicit separator.
#
# Two things that only show up against *real* court PDFs, not hand-written
# samples:
#
# 1. Real reasons are double-spaced, so a single logical paragraph or
#    heading is wrapped across many physical lines by `pdftotext`, often
#    with a blank line between each. `TextBlock(n)` re-joins those lines
#    until the next thing that looks like item `n` or a heading -- it is
#    *not* just `TextToEOL`.
# 2. Real cover pages (title block, party list, coram, table of contents,
#    ...) don't share one layout across courts, so `MetaLine*` will often
#    match nothing at all. Rather than modelling every court's cover page,
#    `FrontMatter` just discards lines up to the first exact "[1]" -- the
#    one format-independent signal that the real reasons have begun.
#    `Paragraph(n)` requiring the *exact* expected next number (not just
#    "any digits") is also what stops an in-text case citation shaped like
#    "[1995] 3 S.C.R. 453" from being mistaken for a paragraph marker: 1995
#    is (almost) never the expected next paragraph number.
# 3. RomanHeading and LetterHeading requiring the exact expected next
#    numeral/letter (I, II, III, ... resetting whenever a roman heading is
#    seen; A, B, C, ... resetting to A under each new roman heading) isn't
#    just discipline for its own sake, the way "(i)" is for subparagraphs
#    in legislation_parser.mojo -- it's load-bearing. I, V, X, L, C, D and
#    M are each individually valid roman numerals, and single-initial
#    abbreviations starting with exactly those letters are everywhere in
#    real legal prose (judge initials like "Côté J.", author initials like
#    "D. B. Nixon" or "L. W. Houlden", reporter abbreviations like "C.B.R."
#    that happen to wrap right after the first letter). An unconstrained
#    RomanHeading/LetterHeading reads any of those, once wrapped to the
#    start of a line, as a bogus new heading and truncates the paragraph
#    it actually belongs to -- confirmed by testing against a real 82-page
#    SCC judgment (Poonian v. British Columbia (Securities Commission),
#    2024 SCC 28), not merely a theoretical concern.
# =============================================================================


def is_digit(c: String) -> Bool:
    return c >= "0" and c <= "9"


def is_lower(c: String) -> Bool:
    return c >= "a" and c <= "z"


def is_upper(c: String) -> Bool:
    return c >= "A" and c <= "Z"


def is_space(c: String) -> Bool:
    return c == " " or c == "\t"


def is_all_caps_heading(line: String) -> Bool:
    var chars = to_codepoints(String(line.strip()))
    if len(chars) == 0:
        return False
    var first = chars[0]
    if is_digit(first) or first == "[" or first == "(":
        return False
    var has_upper = False
    for ch in chars:
        if is_lower(ch):
            return False
        if is_upper(ch):
            has_upper = True
    return has_upper


comptime ALPHABET: StaticString = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"


def next_letter(c: String) raises -> String:
    var alpha = to_codepoints(String(ALPHABET))
    var i = 0
    while i < len(alpha):
        if alpha[i] == c:
            if i + 1 < len(alpha):
                return alpha[i + 1]
            raise Error("no letter after Z")
        i += 1
    raise Error("not a letter: " + c)


# Covers 1-89, comfortably more top-level headings than any real judgment has.
def to_roman(n: Int) raises -> String:
    if n <= 0:
        raise Error("roman numerals must be positive")
    var values: List[Int] = [50, 40, 10, 9, 5, 4, 1]
    var symbols: List[String] = ["L", "XL", "X", "IX", "V", "IV", "I"]
    var result = String("")
    var remaining = n
    var i = 0
    while remaining > 0 and i < len(values):
        while remaining >= values[i]:
            result += symbols[i]
            remaining -= values[i]
        i += 1
    if remaining > 0:
        raise Error("number too large for supported roman range")
    return result


def indent(depth: Int) -> String:
    var s = String("")
    var i = 0
    while i < depth:
        s += "  "
        i += 1
    return s


# -----------------------------------------------------------------------
# AST
# -----------------------------------------------------------------------


@fieldwise_init
struct Heading(Copyable, Movable):
    var marker: String  # "I.", "A.", or "" for a plain all-caps heading
    var level: Int  # 1 = roman / plain, 2 = lettered subheading
    var text: String


@fieldwise_init
struct Paragraph(Copyable, Movable):
    var number: String
    var text: String


comptime Item = Variant[Heading, Paragraph]


@fieldwise_init
struct Judgment(Copyable, Movable, Writable):
    var meta: Dict[String, String]
    var items: List[Item]
    var front_matter_skipped: Int

    def render(self) -> String:
        var out = self.meta.get("style_of_cause", "(untitled)") + "\n"
        var citation = self.meta.get("citation", "")
        if citation.byte_length() > 0:
            out += "Citation: " + citation + "\n"
        var court = self.meta.get("court", "")
        if court.byte_length() > 0:
            out += "Court:    " + court + "\n"
        var docket = self.meta.get("docket", "")
        if docket.byte_length() > 0:
            out += "Docket:   " + docket + "\n"
        var date = self.meta.get("date", "")
        if date.byte_length() > 0:
            out += "Date:     " + date + "\n"
        if self.front_matter_skipped > 0:
            out += "(skipped " + String(self.front_matter_skipped) + " front-matter line(s) before [1])\n"
        out += "\n"
        for item in self.items:
            if item.isa[Heading]():
                var h = item[Heading].copy()
                if h.marker.byte_length() > 0:
                    out += indent(h.level - 1) + h.marker + " " + h.text + "\n"
                else:
                    out += h.text + "\n"
            else:
                var p = item[Paragraph].copy()
                out += "    [" + p.number + "] " + p.text + "\n"
        return out

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.render())


# -----------------------------------------------------------------------
# PEG cursor / parser
# -----------------------------------------------------------------------


def to_codepoints(text: String) -> List[String]:
    var chars: List[String] = []
    for cp in text.codepoint_slices():
        chars.append(String(cp))
    return chars^


struct Cursor(Copyable, Movable):
    # Indexed by codepoint, not byte: Canadian legal text is bilingual and
    # French text (Québec, procès, intitulé, ...) is full of multi-byte
    # UTF-8 characters. Byte-position indexing can land mid-character and
    # is unsafe; walking a pre-split codepoint list sidesteps that entirely.
    var chars: List[String]
    var pos: Int

    def __init__(out self, var text: String):
        self.chars = to_codepoints(text)
        self.pos = 0

    def at_end(self) -> Bool:
        return self.pos >= len(self.chars)

    def peek(self) -> String:
        if self.at_end():
            return ""
        return self.chars[self.pos]

    def advance(mut self):
        self.pos += 1

    def checkpoint(self) -> Int:
        return self.pos

    def reset(mut self, p: Int):
        self.pos = p

    def peek_line(self) -> String:
        var i = self.pos
        var n = len(self.chars)
        var result = String("")
        while i < n and self.chars[i] != "\n":
            result += self.chars[i]
            i += 1
        return result

    # --- terminals -------------------------------------------------------

    def match_literal(mut self, lit: String) raises:
        var lit_chars = to_codepoints(lit)
        var n = len(lit_chars)
        if self.pos + n > len(self.chars):
            raise Error("unexpected end of input, expected '" + lit + "'")
        var i = 0
        while i < n:
            if self.chars[self.pos + i] != lit_chars[i]:
                raise Error("expected '" + lit + "'")
            i += 1
        self.pos += n

    def match_newline(mut self) raises:
        if self.at_end():
            return
        if self.peek() == "\n":
            self.advance()
        else:
            raise Error("expected newline")

    def skip_spaces(mut self):
        while not self.at_end() and is_space(self.peek()):
            self.advance()

    def skip_blank_lines(mut self):
        while True:
            var cp = self.checkpoint()
            self.skip_spaces()
            if not self.at_end() and self.peek() == "\n":
                self.advance()
            else:
                self.reset(cp)
                break

    def parse_digits(mut self) raises -> String:
        if self.at_end() or not is_digit(self.peek()):
            raise Error("expected digit")
        var result = String("")
        while not self.at_end() and is_digit(self.peek()):
            result += self.peek()
            self.advance()
        return result

    def parse_text_to_eol(mut self) raises -> String:
        var result = String("")
        while not self.at_end() and self.peek() != "\n":
            result += self.peek()
            self.advance()
        self.match_newline()
        return String(result.strip())

    # A real court's PDF reasons are double-spaced: every wrapped physical
    # line of a single logical paragraph comes out of `pdftotext` as its
    # own line, often with a blank line between them (see the grammar note
    # at the top of the file). `parse_text_block` re-joins those wrapped
    # lines into one logical paragraph/heading text, stopping only when the
    # next line is unambiguously the start of the *next* item.
    def parse_text_block(mut self, expected_next: Int, expected_letter: String, expected_roman: Int) raises -> String:
        var result = self.parse_text_to_eol()
        while True:
            var cp = self.checkpoint()
            self.skip_blank_lines()
            if self.at_end() or self.looking_at_new_item(expected_next, expected_letter, expected_roman):
                self.reset(cp)
                break
            var cont = self.parse_text_to_eol()
            if cont.byte_length() > 0:
                if result.byte_length() > 0:
                    result += " "
                result += cont
        return result

    # And-predicate: true if "[<n>]" appears right here, without consuming.
    # Checking the *exact* expected next paragraph number (not just "any
    # digits") is what lets this stay unambiguous even though real reasons
    # are full of in-text case citations shaped just like a paragraph
    # marker, e.g. "..., [1995] 3 S.C.R. 453, ..." -- 1995 is never the
    # expected next paragraph number, so it can't be mistaken for one.
    def looking_at_paragraph_number(mut self, n: Int) -> Bool:
        var cp = self.checkpoint()
        try:
            self.match_literal("[" + String(n) + "]")
            self.reset(cp)
            return True
        except:
            self.reset(cp)
            return False

    # And-predicate: true if a heading starts right here, without consuming.
    def looking_at_heading(mut self, expected_next: Int, expected_letter: String, expected_roman: Int) -> Bool:
        var cp = self.checkpoint()
        try:
            _ = self.parse_heading(expected_next, expected_letter, expected_roman)
            self.reset(cp)
            return True
        except:
            self.reset(cp)
            return False

    # And-predicate: true if a new judgment's meta header starts right
    # here, without consuming. A wrapped text block must stop here too --
    # otherwise, when several judgments are concatenated with no separator
    # (see `Document <- Judgment+` at the top of the file), the last
    # paragraph of one judgment greedily swallows the next judgment's
    # "STYLE OF CAUSE:"/"CITATION:"/... lines as if they were its own
    # wrapped continuation text.
    def looking_at_meta_label(mut self) -> Bool:
        var labels: List[String] = [
            "STYLE OF CAUSE:",
            "INTITULÉ:",
            "CITATION:",
            "COURT:",
            "COUR:",
            "DOCKET:",
            "DOSSIER:",
            "DATE:",
        ]
        for label in labels:
            var cp = self.checkpoint()
            try:
                self.match_literal(label)
                self.reset(cp)
                return True
            except:
                self.reset(cp)
        return False

    # And-predicate: true if the next item (paragraph, heading, or the next
    # judgment's meta header) starts here. Used only to decide where a
    # wrapped text block ends.
    def looking_at_new_item(mut self, expected_next: Int, expected_letter: String, expected_roman: Int) -> Bool:
        if self.looking_at_paragraph_number(expected_next):
            return True
        if self.looking_at_meta_label():
            return True
        return self.looking_at_heading(expected_next, expected_letter, expected_roman)

    # Real cover pages (title block, party list, coram, table of contents,
    # ...) don't follow any single layout across courts, so rather than
    # modeling them, skip everything up to the first "[1]" -- the one
    # reliable, format-independent signal that the actual reasons have
    # begun. Metadata extracted from the header (style of cause, citation,
    # ...) is best-effort only, via `parse_meta_lines`'s own labels.
    #
    # A real cover page/table of contents is often itself full of lines
    # that pattern-match as headings (e.g. a table of contents entry "I.
    # Introduction .......... 1" looks exactly like the real "I.
    # Introduction" heading that actually opens the reasons a few lines
    # later). Rather than stopping at the *first* heading-looking line
    # (which would stop inside the table of contents), this keeps track of
    # the *last* heading-looking line seen and, once "[1]" is reached,
    # rewinds to it -- that's the one immediately above "[1]", i.e. the
    # real section heading, not a table-of-contents entry.
    def skip_front_matter(mut self) raises -> Int:
        var skipped = 0
        var last_heading_cp = -1
        while True:
            self.skip_blank_lines()
            if self.at_end() or self.looking_at_paragraph_number(1):
                break
            var line_start = self.checkpoint()
            if self.looking_at_heading(1, "A", 1):
                last_heading_cp = line_start
            else:
                last_heading_cp = -1
            _ = self.parse_text_to_eol()
            skipped += 1
        if last_heading_cp != -1:
            self.reset(last_heading_cp)
            skipped -= 1
        return skipped

    # --- grammar rules -----------------------------------------------------

    def try_meta(mut self, label: String, key: String, mut meta: Dict[String, String]) -> Bool:
        var cp = self.checkpoint()
        try:
            self.match_literal(label)
            self.skip_spaces()
            meta[key] = self.parse_text_to_eol()
            self.skip_blank_lines()
            return True
        except:
            self.reset(cp)
            return False

    def parse_meta_lines(mut self) raises -> Dict[String, String]:
        var meta: Dict[String, String] = {}
        while True:
            var matched = False
            if self.try_meta("STYLE OF CAUSE:", "style_of_cause", meta):
                matched = True
            elif self.try_meta("INTITULÉ:", "style_of_cause", meta):
                matched = True
            elif self.try_meta("CITATION:", "citation", meta):
                matched = True
            elif self.try_meta("COURT:", "court", meta):
                matched = True
            elif self.try_meta("COUR:", "court", meta):
                matched = True
            elif self.try_meta("DOCKET:", "docket", meta):
                matched = True
            elif self.try_meta("DOSSIER:", "docket", meta):
                matched = True
            elif self.try_meta("DATE:", "date", meta):
                matched = True
            if not matched:
                break
        return meta^

    # Requires the *exact* expected next roman numeral, for the same reason
    # `parse_letter_heading` requires the exact expected letter: several
    # roman numerals (I, V, X, L, C, D, M) are themselves common leading
    # letters of a citation abbreviation or author initial once a line
    # wraps -- e.g. a wrapped line starting "D. B. Nixon, eds., ..." or
    # "C.B.R. (6th) 263, aff'd ..." both parse as valid (but bogus)
    # RomanHeadings without this check. Since RomanHeading is tried before
    # LetterHeading, an unconstrained version of this rule would shadow
    # the letter-heading fix above too.
    def parse_roman_heading(mut self, expected_next: Int, expected_letter: String, expected_roman: Int) raises -> Heading:
        var marker = to_roman(expected_roman)
        self.match_literal(marker)
        self.match_literal(".")
        self.skip_spaces()
        var text = self.parse_text_block(expected_next, expected_letter, expected_roman)
        return Heading(marker=marker + ".", level=1, text=text)

    # Requires the *exact* expected next letter, not just "any uppercase
    # letter" -- real legal prose is full of single-initial abbreviations
    # (judge initials like "Côté J.", author initials like "L. W.
    # Houlden") that are syntactically identical to a lettered subheading
    # marker. A wrapped line that happens to start with one of these would
    # otherwise be misread as a bogus "new subheading", corrupting the
    # paragraph it actually belongs to. Requiring the letters to run
    # A, B, C, ... in sequence (reset to "A" after every top-level heading,
    # tracked by the caller) makes a false match exceedingly unlikely,
    # exactly like the "(i)" requirement for subparagraphs in
    # legislation_parser.mojo.
    def parse_letter_heading(mut self, expected_next: Int, expected_letter: String, expected_roman: Int) raises -> Heading:
        self.match_literal(expected_letter)
        self.match_literal(".")
        self.skip_spaces()
        var text = self.parse_text_block(expected_next, expected_letter, expected_roman)
        return Heading(marker=expected_letter + ".", level=2, text=text)

    def parse_plain_heading(mut self) raises -> Heading:
        var line = self.peek_line()
        if not is_all_caps_heading(line):
            raise Error("not a heading line")
        _ = self.parse_text_to_eol()
        return Heading(marker="", level=1, text=String(line.strip()))

    def parse_heading(mut self, expected_next: Int, expected_letter: String, expected_roman: Int) raises -> Heading:
        var cp = self.checkpoint()
        try:
            return self.parse_roman_heading(expected_next, expected_letter, expected_roman)
        except:
            self.reset(cp)
        cp = self.checkpoint()
        try:
            return self.parse_letter_heading(expected_next, expected_letter, expected_roman)
        except:
            self.reset(cp)
        return self.parse_plain_heading()

    def parse_paragraph(mut self, expected_next: Int, expected_letter: String, expected_roman: Int) raises -> Paragraph:
        self.match_literal("[" + String(expected_next) + "]")
        self.skip_spaces()
        var text = self.parse_text_block(expected_next + 1, expected_letter, expected_roman)
        return Paragraph(number=String(expected_next), text=text)

    def parse_item(mut self, expected_next: Int, expected_letter: String, expected_roman: Int) raises -> Item:
        var cp = self.checkpoint()
        try:
            var h = self.parse_heading(expected_next, expected_letter, expected_roman)
            return Item(h^)
        except:
            self.reset(cp)
        var p = self.parse_paragraph(expected_next, expected_letter, expected_roman)
        return Item(p^)

    def parse_judgment(mut self) raises -> Judgment:
        self.skip_blank_lines()
        var meta = self.parse_meta_lines()
        self.skip_blank_lines()
        var skipped = self.skip_front_matter()

        var items: List[Item] = []
        var expected_next = 1
        var expected_letter = String("A")
        var expected_roman = 1
        while True:
            self.skip_blank_lines()
            if self.at_end():
                break
            var cp = self.checkpoint()
            try:
                var it = self.parse_item(expected_next, expected_letter, expected_roman)
                if it.isa[Paragraph]():
                    expected_next += 1
                else:
                    var h = it[Heading].copy()
                    if h.level == 2:
                        expected_letter = next_letter(expected_letter)
                    else:
                        expected_letter = "A"
                        if h.marker.byte_length() > 0:
                            expected_roman += 1
                items.append(it^)
            except:
                self.reset(cp)
                break

        return Judgment(meta=meta^, items=items^, front_matter_skipped=skipped)

    def parse_document(mut self) raises -> List[Judgment]:
        var judgments: List[Judgment] = []
        while True:
            self.skip_blank_lines()
            if self.at_end():
                break
            var before = self.checkpoint()
            var j = self.parse_judgment()
            judgments.append(j^)
            if self.checkpoint() == before:
                raise Error("could not parse content near: " + self.peek_line())
        return judgments^


# -----------------------------------------------------------------------
# Sample input
#
# Two short illustrative judgments -- one in the style of an English-
# language Supreme Court of Canada decision, one in the style of a French-
# language Cour d'appel du Québec decision -- concatenated with no
# separator, to demonstrate that `Document <- Judgment+` finds the boundary
# on its own. Not transcripts of real cases. Feed the parser real judgment
# text (e.g. copied from a CanLII listing) via a file path argument.
# -----------------------------------------------------------------------

comptime SAMPLE_DOCUMENT: StaticString = """STYLE OF CAUSE: Her Majesty the Queen v. John Smith
CITATION: 2021 SCC 5
COURT: Supreme Court of Canada
DOCKET: 38973
DATE: 2021-02-19

I. OVERVIEW
[1] This appeal concerns the interpretation of section 8 of the Charter.
[2] The appellant was convicted at trial and the conviction was upheld by the Court of Appeal.

II. FACTS
[3] On the night in question, police officers stopped the appellant's vehicle.
[4] A search of the vehicle revealed a quantity of a controlled substance.

III. ANALYSIS
A. Standard of Review
[5] Questions of law are reviewed on a standard of correctness.
B. Application
[6] Applying that standard, we conclude the trial judge erred.

IV. DISPOSITION
[7] The appeal is allowed and a new trial is ordered.

INTITULÉ: Sa Majesté la Reine c. Jean Tremblay
CITATION: 2020 QCCA 456
COUR: Cour d'appel du Québec
DOSSIER: 500-10-987654-321
DATE: 2020-11-03

I. APERÇU
[1] Le présent pourvoi porte sur l'interprétation de l'article 8 de la Charte.
[2] L'appelant a été déclaré coupable en première instance.

II. LES FAITS
[3] Les faits ne sont pas contestés par les parties.

MOTIFS
[4] Pour les motifs qui suivent, je suis d'avis d'accueillir le pourvoi.

DISPOSITIF
[5] Le pourvoi est accueilli et un nouveau procès est ordonné.
"""


# Shells out to `pdftotext` (poppler-utils) rather than parsing the PDF
# format directly -- there is no PDF library in Mojo or in this
# environment, and `pdftotext` is already installed. `-layout` preserves
# the page's visual line breaks, which is what keeps "[1] ..." paragraphs
# and headings on their own lines the way the grammar above expects. CanLII
# PDF exports still often carry running headers/footers and page numbers
# that this doesn't strip, so extraction from a PDF is best-effort.
def read_pdf_text(path: String) raises -> String:
    var subprocess = Python.import_module("subprocess")
    var result = subprocess.run(
        Python.list("pdftotext", "-layout", path, "-"),
        capture_output=True,
        text=True,
    )
    if Int(py=result.returncode) != 0:
        raise Error("pdftotext failed on '" + path + "': " + String(py=result.stderr))
    # pdftotext emits a form-feed (\f) at every page break; the grammar has
    # no rule for that byte, so on a real multi-page judgment it would raise
    # right at the boundary. A page break is exactly where a blank line
    # belongs anyway, so normalize \f -> \n.
    return String(py=result.stdout).replace("\f", "\n")


def read_plain_text(path: String) raises -> String:
    var f = open(path, "r")
    var content = f.read()
    f.close()
    return content


# Format dispatch, by extension. Deliberately a closed list rather than a
# fallback-to-plain-text default: an unrecognized extension is far more
# likely to be a typo or an unsupported format (.docx, .html, ...) than
# actual plain text, and silently trying to read it as text would produce
# a confusing parse error far from the real cause. Add a new format by
# adding one more `elif` here -- `read_X_text(path) raises -> String` is
# the whole contract, so the rest of the program doesn't change.
def read_document_text(path: String) raises -> String:
    var lower = path.lower()
    if lower.endswith(".pdf"):
        return read_pdf_text(path)
    elif lower.endswith(".txt"):
        return read_plain_text(path)
    else:
        raise Error("unsupported document format for '" + path + "' -- supported: .pdf, .txt")


def main() raises:
    var args = argv()
    var path = String("")
    var export_path = String("")
    var i = 1
    while i < len(args):
        var a = String(args[i])
        if a == "--":
            pass
        elif a == "--export" or a == "--out" or a == "-o":
            i += 1
            if i >= len(args):
                raise Error(a + " requires a file path argument")
            export_path = String(args[i])
        else:
            path = a
        i += 1

    var content: String
    if path.byte_length() > 0:
        content = read_document_text(path)
        print("Parsing " + path + " ...\n")
    else:
        content = String(SAMPLE_DOCUMENT)
        print("No file given -- parsing the built-in illustrative sample (Canada + Quebec).\n")

    var cur = Cursor(content^)
    var judgments = cur.parse_document()
    print("Parsed " + String(len(judgments)) + " judgment(s):\n")

    if export_path.byte_length() > 0:
        var output = String("")
        for j in judgments:
            output += String(j) + "\n----------------------------------------\n"
        var f = open(export_path, "w")
        f.write(output)
        f.close()
        print("Wrote output to " + export_path)
    else:
        for j in judgments:
            print(j)
            print("----------------------------------------")
