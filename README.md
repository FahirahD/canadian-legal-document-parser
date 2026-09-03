# Canadian Legal Document Parser

*[Lire en français](README.fr.md)*

Hand-written [PEG](https://en.wikipedia.org/wiki/Parsing_expression_grammar) parsers, in [Mojo](https://www.modular.com/mojo), that turn real Canadian (and Quebec) legal documents into structured data: federal **legislation**, court **jurisprudence**, and academic **doctrine**. Each one is built against the actual formatting conventions of real, published PDFs — not a tidy hand-written toy example — and is bilingual (English/French) where the source material is.

Mojo is built primarily for high-performance numerical and AI workloads, so this project also serves as a proof of concept: it shows that Mojo can just as well handle a real-world, text-heavy parsing problem — hand-written recursive-descent grammars over messy, bilingual, PDF-sourced legal text — end to end, at production quality.

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

## Test fixtures — see it actually work

`src/testdata/` holds one real, unmodified PDF per parser (the same files the integration tests and benchmarks use), plus a set of hand-written `.txt` fixtures — organized in the same three type folders — that exercise the grammar features described above without needing `pdftotext`. None of the `.txt` fixtures are transcripts of real documents; they're modeled on the real formatting conventions, the same way each parser's own built-in sample is.

```
src/testdata/legislation/     access_to_information_act.pdf (real)  + 7 .txt fixtures
src/testdata/jurisprudence/   poonian_v_bc_securities_2024scc28.pdf (real) + 7 .txt fixtures
src/testdata/doctrine/        mlj_readability_deficits.pdf (real)  + 6 .txt fixtures
```

Each folder's fixtures cover a different corner of that parser's grammar — deep `(a)(i)(ii)` nesting, fractional section numbers, stacked Part/Division headings, front-matter-heavy cover pages, roman/letter/plain heading mixes, sequential footnotes, bilingual (French-accented) body text, and multiple documents concatenated in one file with no separator. See each folder's filenames for what each one is targeting.

There are two ways to run the whole folder, at two different levels:

**From the shell, for a quick look at real output.** `scripts/dev.sh smoke` calls each parser once per file and reports pass/fail per file:

```bash
scripts/dev.sh smoke                 # all three parsers against all their fixtures
scripts/dev.sh smoke jurisprudence   # just one
```

(or the "Smoke: ..." tasks from VS Code's Task Runner). This is the fastest way to actually watch the parser work end-to-end on 20+ documents, and to eyeball one file's rendered output (`scripts/dev.sh parse <parser> <path>`) rather than trusting the unit test assertions alone.

**As part of the automated test suite, for CI/regression coverage.** Each `src/tests/integration/test_<parser>_integration.mojo` file has, alongside its single deeply-asserted real-PDF test, a `test_all_testdata_fixtures_parse` test that lists `src/testdata/<parser>/` at run time (via `std.os.listdir`) and asserts every file in it parses without raising — collecting failures with their error messages rather than stopping at the first one. It runs wherever the rest of the suite does:

```bash
scripts/dev.sh test integration            # includes it for all three parsers
pixi run test-legislation-integration      # or just one parser's integration suite
```

Because it lists the folder rather than naming files, dropping a new fixture into `src/testdata/<parser>/` gets it covered automatically — no test code changes needed.

## Project layout

```
src/
  parsers/         The three parsers (also runnable directly)
  tests/unit/       Fast, no-I/O tests against hand-written fixtures
  tests/integration/  Tests that parse the real PDFs in src/testdata/<type>/
  benchmarks/       Timing benchmarks for each parser
  testdata/
    legislation/    Sample Acts to parse — 1 real PDF + 7 synthetic .txt fixtures
    jurisprudence/  Sample judgments to parse — 1 real PDF + 7 synthetic .txt fixtures
    doctrine/       Sample articles to parse — 1 real PDF + 6 synthetic .txt fixtures
output/             Example parser output (generated via --export)
scripts/dev.sh      Friendly CLI wrapper around the pixi tasks below
.vscode/            VS Code tasks for the same operations, via Command Palette → Run Task
```

## Getting started

### 1. Install Mojo (via `pixi`)

This project doesn't need a separate Mojo install: [`pixi`](https://pixi.sh) is the package manager, and `pixi.toml`'s `[dependencies]` pulls the `mojo` compiler itself from Modular's conda channel — installing the project *is* installing Mojo, pinned to the version this repo was built against.

1. Install `pixi` itself, if you don't already have it:
   ```bash
   curl -fsSL https://pixi.sh/install.sh | sh
   ```
   (see [pixi.sh](https://pixi.sh) for other platforms/methods.) Restart your shell, or source your shell's rc file, so `pixi` is on `PATH`.
2. From the project root, install the environment (this downloads Mojo + the MAX platform into a local, gitignored `.pixi/` directory — nothing is installed system-wide):
   ```bash
   pixi install
   ```
3. Verify it worked:
   ```bash
   pixi run mojo --version
   ```

> **Windows (via WSL2):** Mojo has no native Windows build, and this repo's `pixi.toml` only declares `platforms = ["linux-64"]`, so `pixi install` will fail on plain Windows (PowerShell/cmd). Install [WSL2](https://learn.microsoft.com/windows/wsl/install) with an Ubuntu distro, then run the steps above (`pixi install`, `scripts/dev.sh`, etc.) from inside the WSL shell — everything works there exactly as on native Linux.

For PDF input specifically (all three parsers accept `.pdf` or `.txt`), you'll also need `pdftotext` — from `poppler-utils` — on your system `PATH`:

```bash
# Debian/Ubuntu
sudo apt install poppler-utils
# macOS
brew install poppler
```

`.txt` input (including every synthetic fixture under `src/testdata/`) needs no extra dependency.

> **If you ever move or rename this project folder**, delete `.pixi/` and re-run `pixi install`: the environment caches some absolute paths at install time, and a stale cache after a move surfaces as `mojo` failing to find its own standard library (`unable to locate module 'std'`) or compiler runtime.

### 2. Run something

```bash
scripts/dev.sh parse doctrine src/testdata/doctrine/01_basic_footnotes.txt
scripts/dev.sh test unit doctrine       # one parser's unit tests
scripts/dev.sh test unit               # all three parsers' unit tests
scripts/dev.sh test integration        # real-PDF integration tests
scripts/dev.sh test all                # everything
scripts/dev.sh bench legislation       # one parser's benchmark
scripts/dev.sh bench                   # all three benchmarks
scripts/dev.sh smoke                   # parse every testdata fixture, report pass/fail
scripts/dev.sh list                    # show the underlying pixi tasks
```

Or call the underlying `pixi` tasks directly — `pixi task list` shows all of them (`parse-doctrine`, `test-legislation`, `bench-jurisprudence`, `test-all`, ...).

### From VS Code

Open the folder, install the recommended [Mojo extension](https://marketplace.visualstudio.com/items?itemName=modular-mojotools.vscode-mojo) when prompted, then **Command Palette → "Tasks: Run Task"** for the same list (test/bench/smoke per parser, or "Test: all"). The "Parse" tasks prompt for a file path, defaulting to the matching sample in `src/testdata/<type>/`.

## What could be done later

- **Structured export formats.** Output today is pretty-printed text; a `--format json` (or similar) would make the parsed AST easy to feed into other tooling.
- **Provincial/territorial legislation.** The legislation grammar targets Justice Laws' federal statute layout specifically; provincial statute publishers use different (though related) conventions.
- **Header/footer stripping.** PDF extraction is best-effort — a more general running-header/footer detector (rather than the current hardcoded patterns) would reduce the amount of hand-cleaning real-world PDFs need.
- **Cross-reference resolution.** None of the parsers currently resolve citations (`section 41`, `[1995] 3 S.C.R. 453`, footnote references) into links between documents — that's a natural next layer once single-document parsing is solid.
- **Amendment history as structured data.** Legislation's trailing amendment citations (`1980-81-82-83, c. 111, Sch. I`) are currently recognized only well enough to *not* be misparsed as new sections; capturing them as their own field would let downstream tooling show a provision's history.
- **A shared CLI/library entry point.** Right now each parser is its own `mojo run`-able file with a duplicated `main()`; as the project grows, a single dispatching entry point (`mojo run src/cli.mojo parse legislation ...`) or a proper package/library surface might be worth it.
