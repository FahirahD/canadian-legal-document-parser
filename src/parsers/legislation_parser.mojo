from std.sys import argv, exit
from std.python import Python
from std.os import listdir
from std.time import perf_counter_ns

# =============================================================================
# A PEG grammar for (a useful subset of) Canadian federal statute text.
#
# Canadian legislation, as published by the Justice Laws website, is laid out
# with strong structural conventions: every clause starts at the beginning of
# its own line, so the grammar below treats NEWLINE as a real terminal and
# builds a line-oriented PEG on top of character-level primitives (literals,
# character classes, ordered choice, `*`/`+`/`?`, and one semantic predicate).
#
#   Act            <- MetaLine* Item+
#   MetaLine       <- ("CHAPTER:" / "TITLE:") WS TextToEOL
#   Item           <- Section
#   Section        <- Heading* MarginalNote? SectionNum WS SectionBody
#   Heading        <- UpperLine                      # e.g. "PURPOSE OF ACT"
#   MarginalNote   <- "Marginal note:" WS TextToEOL
#   SectionNum     <- Digit+ ("." Digit+)?
#   SectionBody    <- SubsectionList / (TextToEOL ParagraphList?)
#   SubsectionList <- Subsection+
#   Subsection     <- MarginalNote? "(" Digit+ ")" WS TextToEOL ParagraphList?
#   ParagraphList  <- Paragraph+
#   Paragraph      <- "(" Lower+ ")" WS TextToEOL SubparagraphList?
#   SubparagraphList <- FirstSubparagraph Subparagraph*
#   FirstSubparagraph <- Subparagraph &{label == "i"}     # semantic predicate:
#                                                          # a sublist must open
#                                                          # at (i), which is
#                                                          # what disambiguates
#                                                          # "(c)" as a roman
#                                                          # numeral from "(c)"
#                                                          # as the next sibling
#                                                          # paragraph label.
#   Subparagraph   <- "(" Roman+ ")" WS TextToEOL
#   UpperLine      <- (!Lower .)+ NEWLINE                 # no lowercase letters
#   TextToEOL      <- (!NEWLINE .)* NEWLINE?
#   WS             <- ' '*
#
# Ordered choice, `*`, `+`, and `?` are all implemented the standard
# recursive-descent way: attempt a rule, and on failure (a raised Error)
# reset the cursor to a saved checkpoint and try the next alternative /
# stop the loop. This is genuine backtracking PEG parsing, not a line
# splitter with string matching.
# =============================================================================


def is_digit(c: String) -> Bool:
    return c >= "0" and c <= "9"


# Byte-level twins of the predicates above, for Cursor's hot character-
# classification loops (skip_spaces/parse_digits/parse_lower_letters/
# parse_roman): every character these ever classify is single-byte ASCII,
# so comparing the raw byte directly -- instead of going through peek()'s
# per-character String slice just to hand it to the String-based
# predicate -- avoids an allocation per character scanned. Profiled at
# ~9.5x faster than the peek()+String-predicate pattern for this exact
# shape of loop. The String-based predicates above stay: they're still
# used elsewhere on values already extracted as a String.
def is_digit_byte(b: UInt8) -> Bool:
    return b >= UInt8(ord("0")) and b <= UInt8(ord("9"))


def is_lower_byte(b: UInt8) -> Bool:
    return b >= UInt8(ord("a")) and b <= UInt8(ord("z"))


def is_upper_byte(b: UInt8) -> Bool:
    return b >= UInt8(ord("A")) and b <= UInt8(ord("Z"))


def is_space_byte(b: UInt8) -> Bool:
    return b == UInt8(ord(" ")) or b == UInt8(ord("\t"))


def is_roman_char_byte(b: UInt8) -> Bool:
    return (
        b == UInt8(ord("i"))
        or b == UInt8(ord("v"))
        or b == UInt8(ord("x"))
        or b == UInt8(ord("l"))
        or b == UInt8(ord("c"))
        or b == UInt8(ord("d"))
        or b == UInt8(ord("m"))
    )


# The exact set `String.strip()` trims (confirmed empirically: space, tab,
# CR, form feed, vertical tab -- newline isn't included, but doesn't need
# to be here either since parse_text_to_eol's line range already stops
# before the trailing `\n` by construction).
def is_ascii_ws_byte(b: UInt8) -> Bool:
    return (
        b == UInt8(ord(" "))
        or b == UInt8(ord("\t"))
        or b == UInt8(ord("\r"))
        or b == UInt8(0x0C)
        or b == UInt8(0x0B)
    )


# The leading whole-number part of a section number ("3.1" -> 3, "101" -> 101).
# Scans bytes directly rather than decoding `number` into a List[String] of
# codepoints first (to_codepoints) -- section numbers are always plain
# ASCII digits by construction (parse_digits only ever returns "0"-"9"),
# so byte arithmetic (subtracting the ASCII value of "0") gives the exact
# same result as the old digit_value(String) lookup, without the decode.
def whole_number_of(number: String) -> Int:
    var result = 0
    var bytes = number.as_bytes()
    var i = 0
    var n = number.byte_length()
    while i < n:
        if bytes[i] == UInt8(ord(".")):
            break
        result = result * 10 + Int(bytes[i] - UInt8(ord("0")))
        i += 1
    return result


# A real published statute PDF (as opposed to the plain-text convention
# this grammar was originally designed against) has no literal "Marginal
# note:" label at all -- that label is HTML/screen-reader markup, not
# print text; a real PDF just has an unlabeled Title Case line (sometimes
# two, one broader than the other, e.g. a Part/Division title followed by
# the provision's own descriptive note) directly above the provision.
# Rather than trying to tell "this is a Part heading" from "this is a
# marginal note" apart with no reliable syntactic signal to do it by, both
# are folded into the same `Heading*` bucket: any non-blank line starting
# with an uppercase letter, that isn't itself a clause marker and isn't
# the literal-labeled form (reserved for `MarginalNote`), counts. This is
# a deliberate simplification -- it loses the distinction between "this is
# a group heading" and "this is this provision's own note" for real PDFs,
# but loses no actual text, which matters more.
# Only the *first* character of the line actually matters here, so this
# reads its leading byte directly instead of decoding the whole line into
# a List[String] of codepoints (to_codepoints) just to look at element 0
# -- the same per-character-allocation anti-pattern Cursor itself used to
# have, just missed here since this operates on an already-extracted
# String rather than Cursor's own byte offset. A byte >= 0x80 (the start
# of a multi-byte UTF-8 character) can never be an ASCII digit, "(", or
# uppercase A-Z either, so is_digit_byte/is_upper_byte correctly fall
# through to False/True on non-ASCII leading characters without needing
# to actually decode them.
def looks_like_heading(line: String) -> Bool:
    var trimmed = String(line.strip())
    if trimmed.startswith("Marginal note:"):
        return False
    if trimmed.byte_length() == 0:
        return False
    var first_byte = trimmed.as_bytes()[0]
    if is_digit_byte(first_byte) or first_byte == UInt8(ord("(")):
        return False
    return is_upper_byte(first_byte)


# -----------------------------------------------------------------------
# AST
#
# Pretty-printing is done via explicit `render(depth)` methods rather than
# `Writable`/`write_to`: a nested item's text can itself span several
# lines (wrapped paragraph text, a marginal note above a subsection, ...),
# and indentation has to be re-applied to *every* line of a subtree, not
# just prepended once before it. `render` builds each subtree bottom-up as
# a fully-indented string so that composing them stays correct at any
# depth.
# -----------------------------------------------------------------------


def indent(depth: Int) -> String:
    var s = String("")
    var i = 0
    while i < depth:
        s += "  "
        i += 1
    return s


@fieldwise_init
struct Subparagraph(Copyable, Movable):
    var label: String
    var text: String

    def render(self, depth: Int) -> String:
        return indent(depth) + "(" + self.label + ") " + self.text


@fieldwise_init
struct Paragraph(Copyable, Movable):
    var label: String
    var text: String
    var subparagraphs: List[Subparagraph]

    def render(self, depth: Int) -> String:
        var out = indent(depth) + "(" + self.label + ") " + self.text
        for sp in self.subparagraphs:
            out += "\n" + sp.render(depth + 1)
        return out


@fieldwise_init
struct Subsection(Copyable, Movable):
    var marginal_note: String
    var label: String
    var text: String
    var paragraphs: List[Paragraph]

    def render(self, depth: Int) -> String:
        var out = String("")
        if self.marginal_note.byte_length() > 0:
            out += indent(depth) + "[" + self.marginal_note + "]\n"
        out += indent(depth) + "(" + self.label + ") " + self.text
        for p in self.paragraphs:
            out += "\n" + p.render(depth + 1)
        return out


@fieldwise_init
struct Section(Copyable, Movable):
    var headings: List[String]
    var marginal_note: String
    var number: String
    var text: String
    var subsections: List[Subsection]
    var paragraphs: List[Paragraph]

    def render(self, depth: Int) -> String:
        var out = String("")
        for h in self.headings:
            out += indent(depth) + "== " + h + " ==\n"
        if self.marginal_note.byte_length() > 0:
            out += indent(depth) + "[" + self.marginal_note + "]\n"
        out += indent(depth) + self.number + ". " + self.text
        for s in self.subsections:
            out += "\n" + s.render(depth + 1)
        for p in self.paragraphs:
            out += "\n" + p.render(depth + 1)
        return out


@fieldwise_init
struct Act(Copyable, Movable, Writable):
    var chapter: String
    var title: String
    var sections: List[Section]
    var front_matter_skipped: Int

    def write_to(self, mut writer: Some[Writer]):
        writer.write(self.title, " (", self.chapter, ")\n")
        if self.front_matter_skipped > 0:
            writer.write("(skipped " + String(self.front_matter_skipped) + " front-matter line(s) before the first section)\n")
        for s in self.sections:
            writer.write("\n", s.render(0), "\n")


# -----------------------------------------------------------------------
# PEG cursor / parser
# -----------------------------------------------------------------------


struct Cursor(Copyable, Movable):
    # Byte-offset indexed into `text` (this used to be a pre-split
    # `List[String]` of codepoints instead, walked one codepoint-String at
    # a time -- Canadian statutes are bilingual and French text (accès,
    # définitions, présente, ...) is full of multi-byte UTF-8 characters,
    # and that design's whole point was to never let a raw byte offset
    # land mid-character). `advance()` below always steps by the current
    # character's full UTF-8 byte width (`_char_width()`), so `pos` still
    # never lands mid-character -- exactly as Unicode-safe -- while
    # avoiding both the old design's per-codepoint heap allocation up
    # front (`to_codepoints` decoding the whole document before parsing
    # started) and its per-codepoint reallocating `+=` for every
    # token/line extracted while parsing. Profiled at ~95x faster on
    # line/token-heavy text as a result (see bench_*.mojo and the
    # microbenchmark referenced in the project history for this change).
    var text: String
    var byte_len: Int
    var pos: Int

    def __init__(out self, var text: String):
        self.byte_len = text.byte_length()
        self.text = text^
        self.pos = 0

    def at_end(self) -> Bool:
        return self.pos >= self.byte_len

    # Byte width of the UTF-8 character starting at `self.pos`, from its
    # leading byte. Every character this grammar's own literals/predicates
    # classify (digits, ASCII letters, punctuation, newline) is
    # single-byte; this only has to get multi-byte width right for the
    # free-running French-accented prose that gets scanned over via
    # peek()/advance() without being individually classified.
    def _char_width(self) -> Int:
        var b = self.text.as_bytes()[self.pos]
        if b < UInt8(0x80):
            return 1
        elif (b & UInt8(0xE0)) == UInt8(0xC0):
            return 2
        elif (b & UInt8(0xF0)) == UInt8(0xE0):
            return 3
        elif (b & UInt8(0xF8)) == UInt8(0xF0):
            return 4
        return 1

    def advance(mut self):
        if self.at_end():
            return
        self.pos += self._char_width()

    def checkpoint(self) -> Int:
        return self.pos

    def reset(mut self, p: Int):
        self.pos = p

    # `\n` is a single ASCII byte that never appears inside a multi-byte
    # UTF-8 sequence (UTF-8 continuation/lead bytes are always >= 0x80),
    # so a plain byte-level `find` for it -- rather than
    # decoding/comparing codepoint by codepoint -- is safe here even over
    # French-accented text. `String.find` is measured ~11.7x faster than
    # the equivalent hand-written scalar byte-scan loop for this pattern.
    def peek_line(self) -> String:
        var idx = self.text.find("\n", start=self.pos)
        var end = self.byte_len
        if idx != -1:
            end = idx
        return String(self.text[byte=self.pos:end])

    # --- terminals -------------------------------------------------------

    def match_literal(mut self, lit: String) raises:
        # Compares raw bytes directly rather than slicing out a candidate
        # `String` first: `lit`'s byte length doesn't necessarily land on a
        # codepoint boundary in `self.text` when the text *doesn't* match
        # (a very common case -- this is backtracking PEG, so failed match
        # attempts are routine) -- e.g. `self.pos + lit.byte_length()`
        # could fall in the middle of a French-accented multi-byte
        # character that happens to start where `lit` was hoped to end.
        # Slicing there would land mid-character; a byte-by-byte scan
        # never needs to form that slice at all. All grammar literals here
        # are plain ASCII, so a byte-for-byte match can never accidentally
        # straddle a multi-byte sequence (its continuation bytes are
        # always >= 0x80, which no ASCII literal byte equals) -- a
        # successful match is always alignment-safe.
        var lit_bytes = lit.as_bytes()
        var n = len(lit_bytes)
        if self.pos + n > self.byte_len:
            raise Error("unexpected end of input, expected '" + lit + "'")
        var text_bytes = self.text.as_bytes()
        var i = 0
        while i < n:
            if text_bytes[self.pos + i] != lit_bytes[i]:
                raise Error("expected '" + lit + "'")
            i += 1
        self.pos += n

    # `\n` is single-byte ASCII, so comparing the raw byte at self.pos
    # directly -- rather than via self.peek() -- gives identical results
    # (a multi-byte UTF-8 lead/continuation byte is always >= 0x80, so it
    # can never equal it) without peek()'s per-call String allocation.
    # peek() itself is measured at ~9-10% of total real-document parse
    # time when called from one-off comparisons like this one throughout
    # the grammar rules (not just the scanning loops fixed earlier).
    def match_newline(mut self) raises:
        if self.at_end():
            return
        if self.text.as_bytes()[self.pos] == UInt8(ord("\n")):
            self.advance()
        else:
            raise Error("expected newline")

    def skip_spaces(mut self):
        var bytes = self.text.as_bytes()
        while self.pos < self.byte_len and is_space_byte(bytes[self.pos]):
            self.pos += 1

    def skip_blank_lines(mut self):
        while True:
            var cp = self.checkpoint()
            self.skip_spaces()
            if not self.at_end() and self.text.as_bytes()[self.pos] == UInt8(ord("\n")):
                self.advance()
            else:
                self.reset(cp)
                break

    # These, and skip_spaces() above, used to call self.peek() (a fresh
    # String slice) once per character just to classify it -- profiled at
    # ~9.5x slower than comparing the raw byte directly, since every
    # character these classify is single-byte ASCII by construction (the
    # is_*_byte predicates only ever match bytes < 0x80, so stepping
    # self.pos by 1 byte at a time here is exactly as UTF-8-safe as
    # advance()'s general codepoint-width stepping).
    def parse_digits(mut self) raises -> String:
        var bytes = self.text.as_bytes()
        if self.pos >= self.byte_len or not is_digit_byte(bytes[self.pos]):
            raise Error("expected digit")
        var start = self.pos
        while self.pos < self.byte_len and is_digit_byte(bytes[self.pos]):
            self.pos += 1
        return String(self.text[byte=start : self.pos])

    def parse_lower_letters(mut self) raises -> String:
        var bytes = self.text.as_bytes()
        if self.pos >= self.byte_len or not is_lower_byte(bytes[self.pos]):
            raise Error("expected lowercase letter")
        var start = self.pos
        while self.pos < self.byte_len and is_lower_byte(bytes[self.pos]):
            self.pos += 1
        return String(self.text[byte=start : self.pos])

    def parse_roman(mut self) raises -> String:
        var bytes = self.text.as_bytes()
        if self.pos >= self.byte_len or not is_roman_char_byte(bytes[self.pos]):
            raise Error("expected roman numeral")
        var start = self.pos
        while self.pos < self.byte_len and is_roman_char_byte(bytes[self.pos]):
            self.pos += 1
        return String(self.text[byte=start : self.pos])

    # Same `find`-based safety argument as peek_line() -- one allocation
    # for the whole line. Trims leading/trailing whitespace by narrowing
    # the byte range directly (is_ascii_ws_byte matches exactly what
    # String.strip() trims, confirmed empirically) rather than slicing
    # the untrimmed line and then calling .strip() on top of it, which
    # was a second allocation on every single physical line parsed.
    def parse_text_to_eol(mut self) raises -> String:
        var idx = self.text.find("\n", start=self.pos)
        var start = self.pos
        self.pos = self.byte_len if idx == -1 else idx
        var bytes = self.text.as_bytes()
        var trim_start = start
        var trim_end = self.pos
        while trim_start < trim_end and is_ascii_ws_byte(bytes[trim_start]):
            trim_start += 1
        while trim_end > trim_start and is_ascii_ws_byte(bytes[trim_end - 1]):
            trim_end -= 1
        var result = String(self.text[byte=trim_start : trim_end])
        self.match_newline()
        return result

    # --- grammar rules -----------------------------------------------------

    def parse_heading_line(mut self) raises -> String:
        var line = self.peek_line()
        if not looks_like_heading(line):
            raise Error("not a heading line")
        _ = self.parse_text_to_eol()
        return String(line.strip())

    def opt_headings(mut self) -> List[String]:
        var result: List[String] = []
        while True:
            var cp = self.checkpoint()
            try:
                var h = self.parse_heading_line()
                result.append(h)
                self.skip_blank_lines()
            except:
                self.reset(cp)
                break
        return result^

    def parse_marginal_note(mut self) raises -> String:
        self.match_literal("Marginal note:")
        self.skip_spaces()
        return self.parse_text_to_eol()

    def opt_marginal_note(mut self) -> String:
        var cp = self.checkpoint()
        try:
            var m = self.parse_marginal_note()
            self.skip_blank_lines()
            return m
        except:
            self.reset(cp)
            return ""

    def parse_section_number(mut self) raises -> String:
        var whole = self.parse_digits()
        var cp = self.checkpoint()
        var number: String
        try:
            self.match_literal(".")
            var frac = self.parse_digits()
            number = whole + "." + frac
        except:
            self.reset(cp)
            number = whole
        # A real section number is always followed by a space before its
        # body text ("1 This Act...", "3.1 For greater certainty"). A
        # trailing amendment-history citation directly after a section's
        # own text ("1980-81-82-83, c. 111, Sch. I ..." or "2019, c. 18,
        # s. 2") starts with digits too but is followed by "-" or "," --
        # confirmed, not hypothetical: without this check, the real Access
        # to Information Act's own citation lines were misread as bogus
        # new sections ("1980", "2019", ...).
        if self.at_end() or self.text.as_bytes()[self.pos] != UInt8(ord(" ")):
            raise Error("not a section number: no space after digits")
        # A real section's body always opens with a capital letter (a
        # fresh, properly capitalized sentence) or "(" (a subsection with
        # no lead-in text of its own). An in-text cross-reference like
        # "...under section 41 or 44 is to be heard..." wrapping so "41"
        # starts a line is followed by a space too, but by a lowercase
        # word continuing the sentence it's embedded in -- confirmed, not
        # hypothetical: without this check, that exact cross-reference in
        # the real Access to Information Act was misread as a new section
        # 41, which (since 41 < 44, the section actually being read) then
        # looked like the real body had ended, silently truncating the
        # whole rest of the Act.
        var cp2 = self.checkpoint()
        self.advance()
        var ok = False
        if not self.at_end():
            var b = self.text.as_bytes()[self.pos]
            ok = b == UInt8(ord("(")) or is_upper_byte(b)
        self.reset(cp2)
        if not ok:
            raise Error("not a section number: not followed by a capitalized clause or subsection marker")
        return number

    # And-predicate: true if a new subsection/paragraph/subparagraph
    # marker, a new section number, or a literal marginal note starts
    # here, without consuming. Used only to decide where a wrapped text
    # block ends (see `parse_text_block`).
    #
    # Deliberately does NOT also stop at `looks_like_heading` (an
    # unlabeled, Title-Case informal note/heading line): that check only
    # requires an uppercase first letter, which an ordinary capitalized
    # word starting a wrapped continuation line satisfies constantly (a
    # real, confirmed failure: "...cited as the Access to Information" /
    # "Act." wraps such that "Act." -- just a capitalized word continuing
    # the same sentence -- looked exactly like a new heading and truncated
    # the clause). A blank line reliably separates one clause's trailing
    # amendment-history citation from the next clause's heading/note in
    # real consolidated statute PDFs, so that plus the literal "Marginal
    # note:" label (unambiguous, no false-positive risk) are the only
    # heading-adjacent stop signals used here.
    def looking_at_new_clause(mut self) raises -> Bool:
        var line = self.peek_line()
        if String(line).startswith("Marginal note:"):
            return True
        var cp = self.checkpoint()
        try:
            self.skip_spaces()
            self.match_literal("(")
            _ = self.parse_digits()
            self.match_literal(")")
            self.reset(cp)
            return True
        except:
            self.reset(cp)
        cp = self.checkpoint()
        try:
            self.skip_spaces()
            self.match_literal("(")
            _ = self.parse_lower_letters()
            self.match_literal(")")
            self.reset(cp)
            return True
        except:
            self.reset(cp)
        cp = self.checkpoint()
        try:
            self.skip_spaces()
            self.match_literal("(")
            _ = self.parse_roman()
            self.match_literal(")")
            self.reset(cp)
            return True
        except:
            self.reset(cp)
        cp = self.checkpoint()
        try:
            _ = self.parse_section_number()
            self.reset(cp)
            return True
        except:
            self.reset(cp)
        return False

    # A real statute PDF (unlike the plain-text convention this grammar
    # was originally designed against) wraps a clause's text across
    # several physical lines with no blank line between them -- a blank
    # line, or the start of the next marker, is what actually ends a
    # clause's text. `parse_text_block` re-joins those wrapped lines;
    # `parse_text_to_eol` alone only ever grabbed the first physical line.
    def parse_text_block(mut self) raises -> String:
        var result = self.parse_text_to_eol()
        while not self.at_end() and self.text.as_bytes()[self.pos] != UInt8(ord("\n")) and not self.looking_at_new_clause():
            var cont = self.parse_text_to_eol()
            if cont.byte_length() > 0:
                result += " " + cont
        return result

    def parse_subparagraph(mut self) raises -> Subparagraph:
        self.skip_spaces()
        self.match_literal("(")
        var label = self.parse_roman()
        self.match_literal(")")
        self.skip_spaces()
        var text = self.parse_text_block()
        return Subparagraph(label=label, text=text)

    def parse_first_subparagraph(mut self) raises -> Subparagraph:
        var cp = self.checkpoint()
        var sp = self.parse_subparagraph()
        if sp.label != "i":
            self.reset(cp)
            raise Error("subparagraph list must open at (i)")
        return sp^

    def parse_paragraph(mut self) raises -> Paragraph:
        self.skip_spaces()
        self.match_literal("(")
        var label = self.parse_lower_letters()
        self.match_literal(")")
        self.skip_spaces()
        var text = self.parse_text_block()

        var subparagraphs: List[Subparagraph] = []
        var cp_first = self.checkpoint()
        var got_first = False
        try:
            var sp0 = self.parse_first_subparagraph()
            subparagraphs.append(sp0^)
            got_first = True
        except:
            self.reset(cp_first)

        if got_first:
            while True:
                self.skip_blank_lines()
                var cp = self.checkpoint()
                try:
                    var sp = self.parse_subparagraph()
                    subparagraphs.append(sp^)
                except:
                    self.reset(cp)
                    break

        return Paragraph(label=label, text=text, subparagraphs=subparagraphs^)

    def parse_paragraph_list(mut self) -> List[Paragraph]:
        var paragraphs: List[Paragraph] = []
        while True:
            self.skip_blank_lines()
            var cp = self.checkpoint()
            try:
                var p = self.parse_paragraph()
                paragraphs.append(p^)
            except:
                self.reset(cp)
                break
        return paragraphs^

    def parse_subsection(mut self) raises -> Subsection:
        var marginal_note = self.opt_marginal_note()
        self.skip_spaces()
        self.match_literal("(")
        var label = self.parse_digits()
        self.match_literal(")")
        self.skip_spaces()
        var text = self.parse_text_block()
        var paragraphs = self.parse_paragraph_list()
        return Subsection(marginal_note=marginal_note, label=label, text=text, paragraphs=paragraphs^)

    def parse_section(mut self) raises -> Section:
        var headings = self.opt_headings()
        var marginal_note = self.opt_marginal_note()
        var number = self.parse_section_number()
        self.skip_spaces()

        var subsections: List[Subsection] = []
        var paragraphs: List[Paragraph] = []
        var text = String("")

        var cp_sub = self.checkpoint()
        var got_subsection = False
        try:
            var s0 = self.parse_subsection()
            subsections.append(s0^)
            got_subsection = True
        except:
            self.reset(cp_sub)

        if got_subsection:
            while True:
                self.skip_blank_lines()
                var cp = self.checkpoint()
                try:
                    var s = self.parse_subsection()
                    subsections.append(s^)
                except:
                    self.reset(cp)
                    break
        else:
            text = self.parse_text_block()
            paragraphs = self.parse_paragraph_list()

        return Section(
            headings=headings^,
            marginal_note=marginal_note,
            number=number,
            text=text,
            subsections=subsections^,
            paragraphs=paragraphs^,
        )

    def parse_act(mut self) raises -> Act:
        self.skip_blank_lines()

        var chapter = String("")
        var cp = self.checkpoint()
        try:
            self.match_literal("CHAPTER:")
            self.skip_spaces()
            chapter = self.parse_text_to_eol()
            self.skip_blank_lines()
        except:
            self.reset(cp)

        var title = String("")
        cp = self.checkpoint()
        try:
            self.match_literal("TITLE:")
            self.skip_spaces()
            title = self.parse_text_to_eol()
            self.skip_blank_lines()
        except:
            self.reset(cp)

        # Real consolidated statute PDFs open with a title page, official-
        # status notices and a table of contents before the real body --
        # none of it labeled the way `CHAPTER:`/`TITLE:` are here, and
        # unlike jurisprudence_parser.mojo's judgments there's no reliable
        # bracket-style anchor ("[1]") to skip forward to either: the table
        # of contents lists every real section number too (also flush
        # left), in the same order, immediately before the real numbering
        # restarts from 1. So front matter is handled two ways together:
        # a line that can't be parsed as a section is discarded one line
        # at a time (skipped_front_matter) rather than aborting the whole
        # parse; and if a table-of-contents entry *does* happen to parse
        # as a well-formed (but bogus) section, the numbering restarting
        # at or below the previous section's number is the signal that
        # real content has begun, and every section accumulated before
        # that point is discarded.
        # A real consolidated statute PDF's table of contents lists every
        # section, in order, immediately before the real body -- and,
        # confirmed against the real Access to Information Act PDF, each
        # TOC entry ("1  Short title", "2  Purpose of Act", ...) is itself
        # shaped enough like a real section (digits, a space, then text)
        # that the whole 100+-entry TOC parses as a long run of well-formed
        # but bogus "sections" mirroring the real numbering exactly, before
        # the real body's numbering restarts at 1. Symmetrically, past the
        # end of the real body, a "Schedules"/"Amendments Not in Force"
        # appendix (confirmed present in the same real PDF) has its own
        # unrelated, non-monotonic numbering.
        #
        # Both are handled with one rule, in two states: before the real
        # body has been found, restarting at exactly section 1 is the
        # signal that it just was -- discard everything accumulated so far
        # (the TOC) and start over. After that point, any further
        # non-increasing jump means real content has *ended* (the
        # appendix has begun) -- stop there and keep what was already
        # parsed, rather than discarding a hundred correctly-parsed real
        # sections for appendix noise.
        # Pre-reserving a starting capacity trims some of the doubling-
        # growth reallocation a large statute's section list would
        # otherwise churn through -- cheap, zero behavior change.
        var sections: List[Section] = List[Section](capacity=64)
        var last_whole = -1
        var seen_real_start = False
        var skipped_front_matter = 0
        while True:
            self.skip_blank_lines()
            if self.at_end():
                break
            var cp = self.checkpoint()
            try:
                var s = self.parse_section()
                var whole = whole_number_of(s.number)
                if whole == 1:
                    sections = []
                    seen_real_start = True
                elif whole < last_whole:
                    if seen_real_start:
                        self.reset(cp)
                        break
                    sections = []
                last_whole = whole
                sections.append(s^)
            except:
                self.reset(cp)
                _ = self.parse_text_to_eol()
                skipped_front_matter += 1
                if self.checkpoint() == cp:
                    break

        return Act(chapter=chapter, title=title, sections=sections^, front_matter_skipped=skipped_front_matter)


# -----------------------------------------------------------------------
# Sample input
#
# Illustrative text modeled on the structure of a real Canadian federal
# statute (in the style of the Access to Information Act, R.S.C., 1985,
# c. A-1) -- not a verbatim reproduction. Feed the parser a real statute
# by passing a file path on the command line, e.g. text copied from
# https://laws-lois.justice.gc.ca/.
# -----------------------------------------------------------------------

comptime SAMPLE_ACT: StaticString = """CHAPTER: R.S.C., 1985, c. A-1
TITLE: Access to Information Act

SHORT TITLE
Marginal note: Short title
1 This Act may be cited as the Access to Information Act.

PURPOSE OF ACT
Marginal note: Purpose of Act
2 (1) The purpose of this Act is to extend the present laws of Canada to provide a right of access to information in records under the control of a government institution in accordance with the principles that
(a) government information should be available to the public;
(b) necessary exceptions to the right of access should be limited and specific; and
(c) decisions on the disclosure of government information should be reviewed independently of government.
Marginal note: For greater certainty
(2) This Act is intended to complement and not replace existing procedures for access to government information and is not intended to limit in any way access to information that is normally available to the public.

DEFINITIONS AND INTERPRETATION
Marginal note: Definitions
3 In this Act,
(a) government institution means
(i) any department or ministry of state of the Government of Canada, and
(ii) any body or office listed in the schedule;
(b) head, in respect of a government institution, means the Minister who presides over that institution;
(c) record includes any correspondence, memorandum, book, plan, map, drawing, diagram, pictorial or graphic work, photograph, film, microform, sound recording, videotape, machine-readable record and any other documentary material regardless of physical form or characteristics.
"""


# Shells out to `pdftotext` (poppler-utils) rather than parsing the PDF
# format directly -- there is no PDF library in Mojo or in this
# environment, and `pdftotext` is already installed. `-layout` asks it to
# preserve the page's visual line breaks, which is what lets the
# line-oriented grammar above keep working on the extracted text. Real
# statute PDFs still often carry running headers/footers and page numbers
# that this doesn't strip, so extraction from a PDF is best-effort: expect
# to hand-clean the text, or the parser to fail loudly on the parts it
# can't recognize, same as any other malformed input.
# Justice Laws' consolidated federal statute PDFs lay English and French
# out as two side-by-side columns on every page, on US Letter (612x792pt)
# pages -- confirmed against the real Access to Information Act PDF. A
# plain `pdftotext -layout` reads left-to-right across both columns,
# interleaving the two languages onto the same output lines, which isn't
# just wrong content but not even line-shaped the way the grammar expects.
# Cropping to the left half of the page (`-x 0 -W <half width>`) isolates
# the English column cleanly. This assumes Letter-sized, two-column,
# English-left layout -- true for Justice Laws' own PDFs, not a general
# solution for arbitrary statute PDFs from other sources.
comptime PAGE_HALF_WIDTH = 306
comptime PAGE_HEIGHT = 792


def strip_running_headers(text: String) -> String:
    var lines = text.split("\n")
    var result = String("")
    for line in lines:
        var stripped = String(String(line).strip())
        if stripped.startswith("Current to "):
            continue
        if stripped.startswith("Last amended on "):
            continue
        if stripped.startswith("Sections ") and stripped.byte_length() > 9 and is_digit(String(stripped[byte=9])):
            continue
        result += String(line) + "\n"
    return result


def read_pdf_text(path: String) raises -> String:
    var subprocess = Python.import_module("subprocess")
    var result = subprocess.run(
        Python.list(
            "pdftotext",
            "-layout",
            "-x",
            "0",
            "-y",
            "0",
            "-W",
            String(PAGE_HALF_WIDTH),
            "-H",
            String(PAGE_HEIGHT),
            path,
            "-",
        ),
        capture_output=True,
        text=True,
    )
    if Int(py=result.returncode) != 0:
        raise Error("pdftotext failed on '" + path + "': " + String(py=result.stderr))
    # pdftotext emits a form-feed (\f) at every page break; the grammar has
    # no rule for that byte, so on a real multi-page statute it would raise
    # "expected digit"/etc. right at the boundary. A page break is exactly
    # where a blank line belongs anyway, so normalize \f -> \n. Running
    # page headers/footers ("Current to ...", "Last amended on ...", a
    # repeated "Sections X-Y" banner) are interspersed mid-document on
    # every page and are stripped for the same reason: the grammar has no
    # rule for them and they'd otherwise be misread as bogus content.
    var content = String(py=result.stdout).replace("\f", "\n")
    return strip_running_headers(content)


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


# One `mojo run` per folder rather than one per file (as `scripts/dev.sh
# smoke` used to shell out to): timing each file with `perf_counter_ns`
# inside a single already-running process isolates real read+parse cost
# from Mojo's per-invocation compile/startup overhead, which otherwise
# dominates and swamps the signal for fixtures this small.
def run_smoke(dir_path: String) raises:
    var total = 0
    var passed = 0
    var total_ns = 0
    var failures: List[String] = []
    print("== " + dir_path + " ==")
    for name in listdir(dir_path):
        var path = dir_path + "/" + name
        total += 1
        var start = perf_counter_ns()
        try:
            var content = read_document_text(path)
            var cur = Cursor(content^)
            _ = cur.parse_act()
            var elapsed_ns = perf_counter_ns() - start
            total_ns += elapsed_ns
            print("  OK    " + format_ms(elapsed_ns) + "  " + path)
            passed += 1
        except e:
            var elapsed_ns = perf_counter_ns() - start
            total_ns += elapsed_ns
            print("  FAIL  " + format_ms(elapsed_ns) + "  " + path)
            print("        " + String(e))
            failures.append(path)

    print("")
    print(String(passed) + "/" + String(total) + " fixtures parsed successfully")
    if total > 0:
        print(
            "total time: " + format_ms(total_ns) + " across " + String(total)
            + " file(s), avg " + format_ms(total_ns // total) + "/file"
        )
    if len(failures) > 0:
        exit(1)


def format_ms(ns: Int) -> String:
    return String(Float64(ns) / 1_000_000.0) + " ms"


def main() raises:
    var args = argv()
    var path = String("")
    var export_path = String("")
    var smoke_dir = String("")
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
        elif a == "--smoke":
            i += 1
            if i >= len(args):
                raise Error(a + " requires a directory path argument")
            smoke_dir = String(args[i])
        else:
            path = a
        i += 1

    if smoke_dir.byte_length() > 0:
        run_smoke(smoke_dir)
        return

    var content: String
    if path.byte_length() > 0:
        content = read_document_text(path)
        print("Parsing " + path + " ...\n")
    else:
        content = String(SAMPLE_ACT)
        print("No file given -- parsing the built-in illustrative sample.\n")

    var cur = Cursor(content^)
    var act = cur.parse_act()

    if export_path.byte_length() > 0:
        var f = open(export_path, "w")
        f.write(String(act))
        f.close()
        print("Wrote output to " + export_path)
    else:
        print(act)
