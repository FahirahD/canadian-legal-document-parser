# Canadian Legal Document Parser

Hand-written [PEG](https://en.wikipedia.org/wiki/Parsing_expression_grammar) parsers, in [Mojo](https://www.modular.com/mojo), that turn real Canadian (and Quebec) legal documents into structured data: federal **legislation**, court **jurisprudence**, and academic **doctrine**. Each one is built against the actual formatting conventions of real, published PDFs — not a tidy hand-written toy example — and is bilingual (English/French) where the source material is.

## Why three parsers, not one

Legislation, case law, and legal scholarship are structured completely differently on the page, so each gets its own grammar rather than one generic "legal document" parser:

| | Legislation | Jurisprudence | Doctrine |
|---|---|---|---|
| **What it is** | Federal statutes (Justice Laws consolidated PDFs) | Court judgments/reasons | Journal articles, treatise chapters, case comments |
| **Numbering** | `1`, `(1)`, `(a)`, `(i)` nested clauses | `[1]`, `[2]`, ... bracketed paragraphs | Sequential footnotes, no paragraph numbers |
| **Headings** | Unlabeled Title-Case lines, `Marginal note:` labels | `I.` / `A.` roman & letter headings, plain ALL-CAPS titles | Same roman/letter/plain convention as jurisprudence |
| **Language** | Bilingual EN/FR, two-column page layout | Bilingual EN/FR header labels | Bilingual EN/FR meta labels |

## What each parser does

### Legislation (`src/parsers/legislation_parser.mojo`)

Parses a federal statute into `Act → Section → Subsection → Paragraph → Subparagraph`, matching the real `1`, `(1)`, `(a)`, `(i)` nesting used in Canadian federal law.

- Recognizes `CHAPTER:`/`TITLE:` metadata and `Marginal note:` labels, and treats any unlabeled Title-Case line as a heading (real PDFs mix Part titles and per-provision notes with no reliable way to tell them apart).
- Re-joins double-spaced, page-wrapped clause text back into single paragraphs.
- Tells a genuine new section number apart from an in-text cross-reference ("under section 41 or 44") and from a trailing amendment-history citation ("1980-81-82-83, c. 111") — both are real failure modes confirmed against the actual *Access to Information Act* PDF.
- Skips a statute's front matter (title page, table of contents) automatically: the TOC parses as a run of "sections" mirroring the real numbering, so the parser discards everything before the numbering restarts at 1, and stops at the first non-increasing jump after that (start of a Schedules/Amendments appendix).
- PDF extraction crops to the left half of the page, because Justice Laws lays English and French out as two side-by-side columns on every page.

### Jurisprudence (`src/parsers/jurisprudence_parser.mojo`)

Parses one or more court judgments into `[1]`, `[2]`, ...-numbered paragraphs, with `I.`/`A.`-style headings — English courts and Quebec (French) courts alike.

- Accepts both English and French header labels (`STYLE OF CAUSE:`/`INTITULÉ:`, `COURT:`/`COUR:`, `DOCKET:`/`DOSSIER:`, ...).
- Discards each judgment's cover page by scanning forward to the first exact `[1]` — real cover pages (title block, party list, coram) have no shared layout across courts, so there's no other reliable anchor.
- Requires paragraph and heading markers to match the *exact* expected next number/letter, which is what stops an in-text citation like `[1995] 3 S.C.R. 453` from being misread as paragraph `[1995]`.
- `Document <- Judgment+`: a single file can hold several concatenated judgments with no separator, and the grammar tells them apart by where one judgment's body stops looking well-formed and the next one's front matter begins.

### Doctrine (`src/parsers/doctrine_parser.mojo`)

Parses legal scholarship — journal articles, treatise chapters, case comments — into a title/author/citation header, roman/letter/plain headings (reused from the jurisprudence grammar, since real articles use the same convention), free-running prose, and a sequentially-numbered footnote apparatus.

- Recognizes `TITLE:`/`TITRE:`, `AUTHOR:`/`AUTEUR:`/`AUTEURE:`, `SOURCE:`, `YEAR:`/`ANNÉE:` metadata, with an implicit-title fallback when no `TITLE:` label is present.
- Distinguishes a footnote (`12. See Côté, ...`) from ordinary prose by requiring the number to match the exact expected next footnote, the same anti-ambiguity trick used for jurisprudence paragraph numbers.

### Shared conventions

All three parsers share one interface, so switching between them is just swapping the executable:

```
mojo run <parser>.mojo [file] [--export|--out|-o <path>]
```

- **No file given** → parses a built-in illustrative sample (handy for a quick smoke test).
- **`.pdf`** → shells out to `pdftotext -layout` (from `poppler-utils`) and normalizes page breaks; **`.txt`** → read directly. Any other extension is rejected rather than silently guessed at.
- **`--export`/`--out`/`-o`** writes the rendered output to a file instead of stdout — see `output/*.txt` for real examples produced this way.
- PDF extraction is best-effort: real statute/judgment/article PDFs carry running headers, footers, and page-number banners that aren't always fully stripped, so hand-cleaning the extracted text is sometimes necessary.

## Project layout

```
src/
  parsers/         The three parsers (also runnable directly)
  tests/unit/       Fast, no-I/O tests against hand-written fixtures
  tests/integration/  Tests that parse the real PDFs in src/testdata/
  benchmarks/       Timing benchmarks for each parser
  testdata/         Real sample PDFs used by the integration tests/benchmarks
output/             Example parser output (generated via --export)
scripts/dev.sh      Friendly CLI wrapper around the pixi tasks below
.vscode/            VS Code tasks for the same operations, via Command Palette → Run Task
```

## Getting started

Requires [`pixi`](https://pixi.sh) and, for PDF input, `pdftotext` (from `poppler-utils`) on your `PATH`.

```bash
pixi install
```

### From a terminal

```bash
scripts/dev.sh parse doctrine src/testdata/mlj_readability_deficits.pdf
scripts/dev.sh test unit doctrine       # one parser's unit tests
scripts/dev.sh test unit               # all three parsers' unit tests
scripts/dev.sh test integration        # real-PDF integration tests
scripts/dev.sh test all                # everything
scripts/dev.sh bench legislation       # one parser's benchmark
scripts/dev.sh bench                   # all three benchmarks
scripts/dev.sh list                    # show the underlying pixi tasks
```

Or call the underlying `pixi` tasks directly — `pixi task list` shows all of them (`parse-doctrine`, `test-legislation`, `bench-jurisprudence`, `test-all`, ...).

### From VS Code

Open the folder, install the recommended [Mojo extension](https://marketplace.visualstudio.com/items?itemName=modular-mojotools.vscode-mojo) when prompted, then **Command Palette → "Tasks: Run Task"** for the same list (test/bench per parser, or "Test: all"). The "Parse" tasks prompt for a file path, defaulting to the matching sample in `src/testdata/`.

## What could be done later

- **Structured export formats.** Output today is pretty-printed text; a `--format json` (or similar) would make the parsed AST easy to feed into other tooling.
- **Provincial/territorial legislation.** The legislation grammar targets Justice Laws' federal statute layout specifically; provincial statute publishers use different (though related) conventions.
- **Header/footer stripping.** PDF extraction is best-effort — a more general running-header/footer detector (rather than the current hardcoded patterns) would reduce the amount of hand-cleaning real-world PDFs need.
- **Cross-reference resolution.** None of the parsers currently resolve citations (`section 41`, `[1995] 3 S.C.R. 453`, footnote references) into links between documents — that's a natural next layer once single-document parsing is solid.
- **Amendment history as structured data.** Legislation's trailing amendment citations (`1980-81-82-83, c. 111, Sch. I`) are currently recognized only well enough to *not* be misparsed as new sections; capturing them as their own field would let downstream tooling show a provision's history.
- **A shared CLI/library entry point.** Right now each parser is its own `mojo run`-able file with a duplicated `main()`; as the project grows, a single dispatching entry point (`mojo run src/cli.mojo parse legislation ...`) or a proper package/library surface might be worth it.
