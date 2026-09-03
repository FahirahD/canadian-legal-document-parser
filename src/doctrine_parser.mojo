from std.sys import argv
from std.utils import Variant
from std.python import Python

# =============================================================================
# A PEG grammar for Canadian (and Quebec) legal doctrine -- academic legal
# writing: journal articles, treatise chapters, case comments. "Doctrine" is
# the third classical source of Canadian/Quebec legal citation alongside
# legislation (legislation_parser.mojo) and jurisprudence
# (jurisprudence_parser.mojo), e.g. a citation reading "P.-A. Côté,
# Interprétation des lois" or "(2023) 67 Can. Bus. L.J. 438".
#
# Doctrine text has a different shape from both of the others: no bracket-
# numbered paragraphs like a judgment and no "(1)(a)(i)" nesting like a
# statute. Structurally it is: a title/author/citation header, then
# roman/lettered/plain headings exactly like jurisprudence_parser.mojo's
# (real articles use the same "I. Introduction" / "A. Sub-heading" / plain
# ALL-CAPS convention), free-running prose paragraphs with no numeric
# anchor at all, and a footnote apparatus numbered sequentially through the
# whole piece.
#
#   Document        <- Doctrine+
#   Doctrine        <- MetaLine* ImplicitTitle? Item*
#   MetaLine        <- MetaLabel WS TextToEOL
#   MetaLabel       <- "TITLE:" / "TITRE:" / "AUTHOR:" / "AUTEUR:" / "AUTEURE:"
#                     / "SOURCE:" / "YEAR:" / "ANNÉE:"
#   ImplicitTitle   <- &{"title" not yet set} TextToEOL   # see note below
#   Item            <- Heading / Footnote(n) / Prose(n)
#   Heading         <- RomanHeading(r) / LetterHeading(l) / PlainHeading
#   RomanHeading(r) <- Roman(r) "." WS TextBlock(n)         # "I. Introduction"
#   LetterHeading(l)<- l "." WS TextBlock(n)                # "A. Sub-heading"
#   PlainHeading    <- UpperLine                            # "ABSTRACT" / "RÉSUMÉ"
#   Footnote(n)     <- n "." WS TextBlock(n+1)              # "12. See Côté, ..."
#   Prose(n)        <- TextBlock(n)                          # ordinary running text
#   TextBlock(n)    <- TextToEOL (!(Footnote(n) / Heading / MetaLabel) TextToEOL)*
#   UpperLine       <- (!Lower .)+ NEWLINE
#   TextToEOL       <- (!NEWLINE .)* NEWLINE?
#   WS              <- ' '*
#
# Reused wholesale from jurisprudence_parser.mojo, for the same reasons:
#
# 1. `TextBlock(n)` joins wrapped physical lines (real PDFs are often
#    double-spaced) until the next real item, exactly as in judgments.
# 2. `Footnote(n)` requires the *exact* expected next footnote number, not
#    just "any digits", for the same reason `Paragraph(n)` does in
#    jurisprudence_parser.mojo: a citation or an in-text numbered list item
#    that happens to start a line ("1. First point", a pinpoint like "45.")
#    would otherwise be misread as a footnote and truncate the prose it
#    belongs to. Real footnotes are numbered strictly sequentially through
#    one piece, so this is a safe, load-bearing constraint, not just
#    discipline. Known, accepted false-positive: an in-text numbered list
#    whose *first* item happens to fall exactly on the expected next
#    footnote number can still be misread as that footnote -- there is no
#    syntactic signal in plain-text-extracted PDF to tell a real footnote
#    marker from a coincidentally-numbered list at that point, so this is
#    documented, not fixed, the same way the roman/letter ambiguities are
#    in jurisprudence_parser.mojo.
# 3. RomanHeading/LetterHeading require the exact expected next roman
#    numeral/letter for the same false-positive-avoidance reason (author
#    initials like "D. B. Nixon" are syntactically identical to a lettered
#    subheading marker once a line wraps).
#
# What's genuinely different from a judgment: doctrine has no bracket-
# numbered anchor at all for ordinary prose (no "[1]"), so paragraphs
# aren't modelled individually -- a whole run of prose between two
# headings/footnotes is captured as one `Prose` item, not split at
# sentence or paragraph boundaries. This is a deliberate simplification:
# recovering true paragraph breaks from a double-spaced PDF with no
# numeric anchor is not reliably possible from text layout alone, so this
# grammar doesn't pretend to.
#
# Real journal PDFs also don't print a literal "TITLE:" label -- the title
# is just the first line of the document (sometimes in small-caps type
# that `pdftotext` renders with stray internal spaces, e.g. "F AILURE TO A
# DAPT" for "FAILURE TO ADAPT" -- captured verbatim regardless, since this
# grammar has no way to know a font was small-caps). `ImplicitTitle` is the
# doctrine-specific analogue of jurisprudence_parser.mojo's front-matter
# skip: if no `MetaLine` set a title, the first line that isn't itself a
# heading or footnote is taken as the title.
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


# Covers 1-89, comfortably more top-level headings than any real article has.
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
struct Footnote(Copyable, Movable):
    var number: String
    var text: String


@fieldwise_init
struct Prose(Copyable, Movable):
    var text: String


comptime Item = Variant[Heading, Footnote, Prose]


@fieldwise_init
struct Doctrine(Copyable, Movable, Writable):
    var meta: Dict[String, String]
    var items: List[Item]

    def render(self) -> String:
        var out = self.meta.get("title", "(untitled)") + "\n"
        var author = self.meta.get("author", "")
        if author.byte_length() > 0:
            out += "Author: " + author + "\n"
        var source = self.meta.get("source", "")
        if source.byte_length() > 0:
            out += "Source: " + source + "\n"
        var year = self.meta.get("year", "")
        if year.byte_length() > 0:
            out += "Year:   " + year + "\n"
        out += "\n"
        for item in self.items:
            if item.isa[Heading]():
                var h = item[Heading].copy()
                if h.marker.byte_length() > 0:
                    out += indent(h.level - 1) + h.marker + " " + h.text + "\n"
                else:
                    out += h.text + "\n"
            elif item.isa[Footnote]():
                var f = item[Footnote].copy()
                out += "    [" + f.number + "] " + f.text + "\n"
            else:
                var p = item[Prose].copy()
                out += "  " + p.text + "\n"
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
    # Indexed by codepoint, not byte -- see legislation_parser.mojo /
    # jurisprudence_parser.mojo for why: Canadian legal text is bilingual
    # and byte-position indexing is unsafe on multi-byte UTF-8 characters.
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

    def parse_text_to_eol(mut self) raises -> String:
        var result = String("")
        while not self.at_end() and self.peek() != "\n":
            result += self.peek()
            self.advance()
        self.match_newline()
        return String(result.strip())

    # Joins wrapped physical lines of one logical heading/footnote/prose
    # block into one string, stopping only when the next line is
    # unambiguously the start of the next item. See the grammar note at
    # the top of the file.
    def parse_text_block(mut self, expected_footnote: Int, expected_letter: String, expected_roman: Int) raises -> String:
        var result = self.parse_text_to_eol()
        while True:
            var cp = self.checkpoint()
            self.skip_blank_lines()
            if self.at_end() or self.looking_at_new_item(expected_footnote, expected_letter, expected_roman):
                self.reset(cp)
                break
            var cont = self.parse_text_to_eol()
            if cont.byte_length() > 0:
                if result.byte_length() > 0:
                    result += " "
                result += cont
        return result

    # And-predicate: true if "<n>." appears right here, without consuming.
    def looking_at_footnote_number(mut self, n: Int) -> Bool:
        var cp = self.checkpoint()
        try:
            self.match_literal(String(n) + ".")
            self.reset(cp)
            return True
        except:
            self.reset(cp)
            return False

    # And-predicate: true if a heading starts right here, without consuming.
    def looking_at_heading(mut self, expected_letter: String, expected_roman: Int) -> Bool:
        var cp = self.checkpoint()
        try:
            _ = self.parse_heading(expected_letter, expected_roman)
            self.reset(cp)
            return True
        except:
            self.reset(cp)
            return False

    # And-predicate: true if a new doctrine's meta header starts right
    # here, without consuming. A wrapped text block must stop here too --
    # otherwise, when several pieces are concatenated with no separator,
    # the last prose block of one piece greedily swallows the next piece's
    # "TITLE:"/"AUTHOR:"/... lines as if they were its own continuation.
    def looking_at_meta_label(mut self) -> Bool:
        var labels: List[String] = [
            "TITLE:",
            "TITRE:",
            "AUTHOR:",
            "AUTEURE:",
            "AUTEUR:",
            "SOURCE:",
            "YEAR:",
            "ANNÉE:",
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

    # And-predicate: true if the next item (footnote, heading, or the next
    # doctrine's meta header) starts here. Used only to decide where a
    # wrapped text block ends.
    def looking_at_new_item(mut self, expected_footnote: Int, expected_letter: String, expected_roman: Int) -> Bool:
        if self.looking_at_footnote_number(expected_footnote):
            return True
        if self.looking_at_meta_label():
            return True
        return self.looking_at_heading(expected_letter, expected_roman)

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
            if self.try_meta("TITLE:", "title", meta):
                matched = True
            elif self.try_meta("TITRE:", "title", meta):
                matched = True
            elif self.try_meta("AUTHOR:", "author", meta):
                matched = True
            elif self.try_meta("AUTEURE:", "author", meta):
                matched = True
            elif self.try_meta("AUTEUR:", "author", meta):
                matched = True
            elif self.try_meta("SOURCE:", "source", meta):
                matched = True
            elif self.try_meta("YEAR:", "year", meta):
                matched = True
            elif self.try_meta("ANNÉE:", "year", meta):
                matched = True
            if not matched:
                break
        return meta^

    # Doctrine-specific analogue of jurisprudence_parser.mojo's front-matter
    # skip (see the grammar note at the top of the file): a real journal
    # PDF has no literal "TITLE:" label, just the title as the very first
    # line. Only fires when no MetaLine already supplied a title, and only
    # consumes a line that doesn't itself look like a heading or footnote.
    def maybe_implicit_title(mut self, mut meta: Dict[String, String]) raises:
        if "title" in meta:
            return
        self.skip_blank_lines()
        if self.at_end():
            return
        if self.looking_at_footnote_number(1) or self.looking_at_heading("A", 1):
            return
        meta["title"] = self.parse_text_to_eol()
        self.skip_blank_lines()

    # Unlike jurisprudence_parser.mojo's headings, this does NOT use
    # `parse_text_block` for the heading's own text -- doctrine prose has
    # no anchor marker of its own (no "[1]"), so a heading's text-block
    # scan would keep merging unmarked prose into itself indefinitely,
    # only ever stopping when it coincidentally stumbled onto text that
    # happened to match the *stale* (not-yet-advanced) expected
    # letter/roman counters, since those only update once the heading
    # item returns to the caller's loop. A heading is just its own single
    # line; everything after it becomes the next (separate) Prose item,
    # parsed with correctly-updated counters. Known limitation: a heading
    # whose own title wraps across two physical lines in a real PDF is not
    # rejoined -- only its first line is captured.
    def parse_roman_heading(mut self, expected_roman: Int) raises -> Heading:
        var marker = to_roman(expected_roman)
        self.match_literal(marker)
        self.match_literal(".")
        self.skip_spaces()
        var text = self.parse_text_to_eol()
        return Heading(marker=marker + ".", level=1, text=text)

    def parse_letter_heading(mut self, expected_letter: String) raises -> Heading:
        self.match_literal(expected_letter)
        self.match_literal(".")
        self.skip_spaces()
        var text = self.parse_text_to_eol()
        return Heading(marker=expected_letter + ".", level=2, text=text)

    def parse_plain_heading(mut self) raises -> Heading:
        var line = self.peek_line()
        if not is_all_caps_heading(line):
            raise Error("not a heading line")
        _ = self.parse_text_to_eol()
        return Heading(marker="", level=1, text=String(line.strip()))

    def parse_heading(mut self, expected_letter: String, expected_roman: Int) raises -> Heading:
        var cp = self.checkpoint()
        try:
            return self.parse_roman_heading(expected_roman)
        except:
            self.reset(cp)
        cp = self.checkpoint()
        try:
            return self.parse_letter_heading(expected_letter)
        except:
            self.reset(cp)
        return self.parse_plain_heading()

    def parse_footnote(mut self, expected_footnote: Int, expected_letter: String, expected_roman: Int) raises -> Footnote:
        self.match_literal(String(expected_footnote) + ".")
        self.skip_spaces()
        var text = self.parse_text_block(expected_footnote + 1, expected_letter, expected_roman)
        return Footnote(number=String(expected_footnote), text=text)

    # Prose is the unconditional fallback in `parse_item`'s ordered choice
    # (tried after Heading and Footnote both fail), unlike them it has no
    # marker of its own that gates its *first* line -- `parse_text_block`
    # only ever checks "is this a new item" before consuming a
    # *continuation* line, not before consuming its very first one. Without
    # this explicit guard, Prose would blindly swallow a line that looks
    # exactly like the next concatenated doctrine's "TITLE:"/"AUTEUR:"/...
    # header as if it were its own text, the same class of bug the
    # equivalent meta-label lookahead fixes for continuation lines in
    # jurisprudence_parser.mojo.
    def parse_prose(mut self, expected_footnote: Int, expected_letter: String, expected_roman: Int) raises -> Prose:
        if self.looking_at_meta_label():
            raise Error("meta label, not prose")
        var text = self.parse_text_block(expected_footnote, expected_letter, expected_roman)
        if text.byte_length() == 0:
            raise Error("empty prose block")
        return Prose(text=text)

    def parse_item(mut self, expected_footnote: Int, expected_letter: String, expected_roman: Int) raises -> Item:
        var cp = self.checkpoint()
        try:
            var h = self.parse_heading(expected_letter, expected_roman)
            return Item(h^)
        except:
            self.reset(cp)
        cp = self.checkpoint()
        try:
            var f = self.parse_footnote(expected_footnote, expected_letter, expected_roman)
            return Item(f^)
        except:
            self.reset(cp)
        var p = self.parse_prose(expected_footnote, expected_letter, expected_roman)
        return Item(p^)

    def parse_doctrine(mut self) raises -> Doctrine:
        self.skip_blank_lines()
        var meta = self.parse_meta_lines()
        self.skip_blank_lines()
        self.maybe_implicit_title(meta)

        var items: List[Item] = []
        var expected_footnote = 1
        var expected_letter = String("A")
        var expected_roman = 1
        while True:
            self.skip_blank_lines()
            if self.at_end():
                break
            var cp = self.checkpoint()
            try:
                var it = self.parse_item(expected_footnote, expected_letter, expected_roman)
                if it.isa[Footnote]():
                    expected_footnote += 1
                elif it.isa[Heading]():
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

        return Doctrine(meta=meta^, items=items^)

    def parse_document(mut self) raises -> List[Doctrine]:
        var pieces: List[Doctrine] = []
        while True:
            self.skip_blank_lines()
            if self.at_end():
                break
            var before = self.checkpoint()
            var d = self.parse_doctrine()
            pieces.append(d^)
            if self.checkpoint() == before:
                raise Error("could not parse content near: " + self.peek_line())
        return pieces^


# -----------------------------------------------------------------------
# Sample input
#
# Two short illustrative doctrine excerpts -- one in the style of an
# English-language Canadian law review article, one in the style of a
# French-language Quebec legal commentary -- concatenated with no
# separator, to demonstrate that `Document <- Doctrine+` finds the
# boundary on its own, and exercising every grammar rule (roman heading,
# lettered subheading, plain heading, sequential footnotes). Not
# transcripts of real articles. Feed the parser a real doctrine PDF via a
# file path argument.
# -----------------------------------------------------------------------

comptime SAMPLE_DOCUMENT: StaticString = """TITLE: The Fresh Start Principle in Canadian Bankruptcy Law
AUTHOR: J. Smith
SOURCE: (2024) 12 Can. Bus. L.J. 45
YEAR: 2024

I. Introduction
The fresh start principle animates the discharge provisions of the
Bankruptcy and Insolvency Act.1 It reflects a policy choice to favour the
rehabilitation of honest but unfortunate debtors over the interests of
their creditors, subject to the narrow exceptions in section 178(1).2

II. The Statutory Exceptions
A. Debts Arising from Fraud
Courts have consistently read the fraud exception narrowly.3 The leading
authority remains the Supreme Court's decision in Moloney.4
B. Regulatory Penalties
Administrative penalties present a harder case, since they are not
imposed by a court in the traditional sense.5

III. Conclusion
The exceptions in section 178(1) should continue to be construed
narrowly, consistent with the rehabilitative purpose of the Act.

1. Bankruptcy and Insolvency Act, RSC 1985, c B-3, s 178(1).
2. Ibid.
3. Industrial Acceptance Corp v Lalonde, [1952] 2 SCR 109.
4. Alberta (Attorney General) v Moloney, 2015 SCC 51, [2015] 3 SCR 327.
5. Poonian v British Columbia (Securities Commission), 2024 SCC 28.

TITRE: Le principe du nouveau départ en droit québécois de la faillite
AUTEURE: M. Tremblay
SOURCE: (2023) 64 C de D 201
ANNÉE: 2023

I. Introduction
Le principe du nouveau départ demeure au coeur du droit de la faillite
canadien.1 Les tribunaux québécois ont généralement suivi l'approche
retenue par la Cour suprême.2

CONCLUSION
Les exceptions prévues à l'article 178(1) doivent continuer d'être
interprétées de façon restrictive.

1. Loi sur la faillite et l'insolvabilité, LRC 1985, c B-3, art 178(1).
2. Alberta (Procureur général) c Moloney, 2015 CSC 51, [2015] 3 RCS 327.
"""


# Shells out to `pdftotext` (poppler-utils) rather than parsing the PDF
# format directly -- there is no PDF library in Mojo or in this
# environment, and `pdftotext` is already installed. `-layout` preserves
# the page's visual line breaks. Real journal PDFs carry running
# headers/footers and page-number banners that this doesn't strip, so
# extraction from a PDF is best-effort.
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
    # no rule for that byte. A page break is exactly where a blank line
    # belongs anyway, so normalize \f -> \n.
    return String(py=result.stdout).replace("\f", "\n")


def read_plain_text(path: String) raises -> String:
    var f = open(path, "r")
    var content = f.read()
    f.close()
    return content


# Format dispatch, by extension -- see legislation_parser.mojo /
# jurisprudence_parser.mojo for why this is a closed list rather than a
# fallback-to-plain-text default.
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
    var pieces = cur.parse_document()
    print("Parsed " + String(len(pieces)) + " doctrine document(s):\n")

    if export_path.byte_length() > 0:
        var output = String("")
        for d in pieces:
            output += String(d) + "\n----------------------------------------\n"
        var f = open(export_path, "w")
        f.write(output)
        f.close()
        print("Wrote output to " + export_path)
    else:
        for d in pieces:
            print(d)
            print("----------------------------------------")
