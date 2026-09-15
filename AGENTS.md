# AGENTS.md

Single-file Ruby CLI that converts `.csv` files to dBase III `.dbf`.
Everything lives in `csv_to_dbf_converter.rb`; there is no `lib/`, no test suite, no Rakefile, and `Gemfile` declares no gems (stdlib `csv` + `date` + `fileutils` only).

## Running

- `ruby csv_to_dbf_converter.rb` (Ruby 4.0.6 per `.ruby-version`; bundler not required).
- The script is **fully interactive**: it shows a menu (1 = convert all, 2 = convert one, 3 = report, 4 = exit) in a loop, prints results without clearing the screen, and blocks on `Enter` after every action plus a final exit prompt. Do not run it expecting it to return; piping stdin or running under a non-TTY can still hang on the final `$stdin.gets`. To drive it non-interactively, feed input including the trailing `Enter`, e.g. `printf '1\n\n3\n\n4\n\n' | ruby csv_to_dbf_converter.rb`.
- ANSI colors are auto-disabled when `$stdout` is not a TTY, so piped output is plain text.
- Windows 11 launcher: `run.bat` sets the console to UTF-8 (`chcp 65001`), checks for Ruby in `PATH`, then runs the script.

## Directories (derived from the script's own location)

- `CSV/` — source; option 1 creates it and reports when missing/empty.
- `Converted_CSV/` — successfully converted `.csv` files are **moved** here.
- `DBF/` — generated `.dbf` files.
- `conversion.log` — tab-separated journal (`epoch\tstatus\tname\tdetail`) appended for every processed file (`ok`/`skipped`/`error`). Logging failures are swallowed so they never break a conversion.
- `Logs/` — monthly archives; on the first run/write of a new month the previous `conversion.log` is renamed to `Logs/conversion_<YYYY-MM>.log` (`archive_log_if_needed`, triggered at startup and before each write). Option 3 reads the current log **and** all archives, so the rolling window isn't truncated by archiving.
- Option 3 prints rolling 24h/7d/30d counts for converted/skipped/errored files plus all-time totals.
- Name collisions are auto-renamed with `_1`, `_2`, … via `unique_path`. Empty/headerless/failed CSVs stay in `CSV/`.

## Encoding

- Input CSV is auto-detected: BOM (UTF-8/UTF-16LE/BE), valid UTF-8, UTF-16 without BOM, then a best-effort heuristic among Windows-1251/KOI8-R/CP866 (default Windows-1251). Everything is transcoded to UTF-8, then parsed with `;` separator and `liberal_parsing: true`.
- Output DBF data and field names are always encoded to **windows-1251** (target is 1C). Unmappable characters are dropped (`replace: ''`). Field names are truncated to 10 **bytes**; empty headers become `COL_<index>`.

## Format quirks (do not "fix" without understanding)

- Output is DBF level 3 (marker `0x03`), language-driver byte `0xC9` (cp1251), **all fields type `C`** (character). No numeric/date field types.
- Field width = max byte length of column data, clamped to 1..254; values are space-padded/truncated; record ends with `0x1A`.
- Option 1 runs non-recursively over `CSV/*.csv` (case-insensitive). Option 2 accepts a bare name (looked up in `CSV/`, `.csv` appended if needed) or a full path.

## Conventions

- User-facing strings are Russian; keep them Russian and use the `UI` module helper methods for output.
- `CSV/`, `Converted_CSV/`, `DBF/`, `Logs/` and `conversion.log` are runtime data (untracked); don't commit them.
- RuboCop/Solargraph config exists only via `.solargraph.yml` (no `.rubocop.yml`); there is no configured lint/test command to run. RuboCop defaults flag only Metrics/Style, no Lint offenses.
