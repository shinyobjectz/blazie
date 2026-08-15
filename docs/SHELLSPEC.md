# SHELLSPEC — what the sandbox shell IS

*The contract of `Blazie.Lua.Shell`, written down. For the DOCUMENTED subset
below, `test/shell_bash_differential_test.exs` runs the same script under
`/bin/bash` and under this shell and asserts byte-identical stdout — a
divergence is either a bug fixed or a line added here. Everything outside
the subset is this shell's own, deliberately.*

## The model

- The "filesystem" is a flat `key → bytes` map. Directories are implicit in
  key names; `mkdir` is a successful no-op; there are no symlinks, no
  permissions, no metadata beyond size. `cd` sets a PREFIX that relative
  keys resolve under (`..` and `/` fold as expected); no key ever touches a
  host path.
- The shell is a pure function per invocation: `cwd` and variables reset
  every `sh(...)` call; only file changes persist (they are the workspace).
- Determinism: same line + same files + same `at` → the same output,
  forever. `date` reads `at`; `whoami` reads the run's provenance id; there
  is no `$RANDOM`, no clock, no environment inheritance.
- Streams: stdout and stderr are separate; `2>`, `2>>`, `2>&1` apply where
  they stand in a pipeline (per segment). The Lua-facing `sh()` returns
  `display, rc, err` (display = stdout+stderr merged, as a terminal shows).
- Output is capped (default 4MB): exceeding it ends the run with rc 141 and
  a refusal naming the repair.

## Grammar (bash-conformant subset)

- Pipelines `a | b | c`; sequencing `;`; short-circuit `&&` / `||`.
- Redirects at any pipeline position: `>`, `>>`, `2>`, `2>>`, `2>&1`.
- Variables: `NAME=value`, `$NAME`, `${NAME}`, `$?`.
- Substitution `$(...)` — subshell semantics: its file writes persist, its
  variable changes do not; trailing newlines stripped; unquoted results
  word-split.
- Arithmetic `$((...))`: integers, `+ - * / %`, parens, unary minus, bare
  variable names (unset → 0).
- Blocks: `for NAME in WORDS; do ...; done`, `while CHAIN; do ...; done`
  (1M-iteration guard), `if CHAIN; then ... [else ...] fi` — and a block
  followed by `|` or a redirect feeds its WHOLE output onward (bash needs
  the same shape; this is conformant).
- `test` / `[ ... ]`: `-f KEY`, `-z S`, `-n S`, `A = B`, `A != B`,
  `N -eq/-ne/-lt/-le/-gt/-ge M`, bare-string truthiness.
- Quoting: `'...'` literal (no expansion, no globs); `"..."` expands `$`
  but never globs or word-splits; bare words expand, word-split, and glob.
- Globs: `*` never crosses `/`; `**` does; no match leaves the pattern
  literal (bash default nullglob-off behavior).

## Tools (bash/coreutils-conformant subset)

basename · cat · cut (`-d -f`, `-c A-B`) · dirname · echo · false · grep
(substring; `-c -v -i -n`, `-E` regex) · head/tail (`-N`, `-n N`) · nl ·
paste · rev · seq · sort (`-n -r`) · tac · tee (`-a`) · tr (ranges, `-d`) ·
true · uniq · wc (`-l -w -c`) · sed (`s/pat/rep/[g]` only — pattern is
BRE-lite: literals plus `. * ^ $ [...]`; `&` in replacement).

## This shell's own (excluded from the differential, by design)

- `ls` lists ALL keys recursively (there are no directories to stop at).
- `find [PREFIX] [-name GLOB]` — a subset syntax over keys.
- `diff` — `< left` / `> right` blocks with `---`, rc 1 on difference; not
  ed-script format.
- `uniq -c` — `N line` with a single space, not column-aligned.
- `stat`, `du` — byte counts over keys, own formats.
- `date`, `whoami` — deterministic from `at`/`by`, never the clock.
- `help`, `upper`, `lower`, `mkdir` (no-op), `sha256` (bare hex).
- Missing on purpose: processes/`&`/subshell-groups `( )`/`{ }`, heredocs,
  `<` input redirect (pipe instead), `case`, shell functions (Lua is the
  function layer), `env`/`export` (no environment exists), `read` (no tty),
  network anything.
