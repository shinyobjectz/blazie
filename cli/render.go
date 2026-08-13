package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
)

// How things look on the way out.
//
// One rule runs through this file: the repair is the point. Every other piece
// of an error — the status, the problem, the stack it came from — tells you
// that something went wrong, and only the repair tells you what to do instead.
// So the repair gets its own line, its own indent, and the emphasis if there is
// any to be had.

// isTTY reports whether w is a terminal, which decides emphasis and whether a
// prompt is worth asking. Piped output gets no escape codes.
func isTTY(w io.Writer) bool {
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	if os.Getenv("NO_COLOR") != "" || os.Getenv("TERM") == "dumb" {
		return false
	}
	info, err := f.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}

const (
	ansiBold  = "\x1b[1m"
	ansiDim   = "\x1b[2m"
	ansiReset = "\x1b[0m"
)

type style struct{ on bool }

func styleFor(w io.Writer) style { return style{on: isTTY(w)} }

func (s style) bold(text string) string {
	if !s.on {
		return text
	}
	return ansiBold + text + ansiReset
}

func (s style) dim(text string) string {
	if !s.on {
		return text
	}
	return ansiDim + text + ansiReset
}

// RenderRefusal writes a refusal so the repair cannot be missed.
//
// The shape is deliberate: one short line naming what was refused, a blank
// line, and then the repair indented on its own. Somebody skimming a wall of
// terminal output should find the sentence that tells them what to do.
func RenderRefusal(w io.Writer, err error) {
	s := styleFor(w)

	refusal, ok := err.(*Refusal)
	if !ok {
		fmt.Fprintf(w, "%s %v\n", s.bold("blazie:"), err)
		return
	}

	head := "refused — " + refusal.Problem
	if refusal.Status != 0 {
		head += s.dim(fmt.Sprintf(" (%d)", refusal.Status))
	}
	fmt.Fprintf(w, "%s %s\n", s.bold("blazie:"), head)

	if refusal.Repair == "" {
		// Worth naming rather than passing over: a refusal without a repair is
		// this database breaking its own rule, and the person seeing it is the
		// only one who can report it.
		fmt.Fprintf(w, "\n    %s\n", s.dim("(the node sent no repair, which it is supposed to)"))
		return
	}

	fmt.Fprintf(w, "\n%s\n", indent(wrap(refusal.Repair, 72), "    "))
}

// RenderRefusalJSON writes the refusal as the node phrased it, so a script sees
// the same problem and repair a person would.
func RenderRefusalJSON(w io.Writer, err error) {
	refusal, ok := err.(*Refusal)
	if !ok {
		refusal = &Refusal{Problem: "cli_failed", Repair: err.Error()}
	}
	writeJSON(w, map[string]any{"error": refusal})
}

func writeJSON(w io.Writer, v any) {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

// ── facts as a table ────────────────────────────────────────────────────────

// RenderFacts prints facts in the order the node answered with them.
//
// Nothing is truncated. A value cut off at the terminal width is a value you
// cannot act on, and hunting for the flag that turns truncation off is worse
// than a wrapped line. `--json` is there for anything that wants shaping.
func RenderFacts(w io.Writer, facts []Fact) {
	s := styleFor(w)

	if len(facts) == 0 {
		fmt.Fprintln(w, s.dim("no facts answer that question"))
		return
	}

	rows := make([][]string, 0, len(facts))
	for _, f := range facts {
		by := f.Producer()
		if by == "" {
			// Empty means no formula and no job produced it — it came from
			// outside. Shown rather than blank, because provenance is the
			// reason this column exists at all.
			by = "—"
		}
		rows = append(rows, []string{
			scalar(f.ID),
			f.Attribute,
			scalar(f.Value),
			strconv.FormatInt(f.Tx, 10),
			by,
		})
	}

	renderTable(w, []string{"id", "attribute", "value", "tx", "by"}, rows)
	fmt.Fprintf(w, "\n%s\n", s.dim(plural(len(facts), "fact", "facts")))
}

func renderTable(w io.Writer, header []string, rows [][]string) {
	s := styleFor(w)

	widths := make([]int, len(header))
	for i, h := range header {
		widths[i] = len(h)
	}
	for _, row := range rows {
		for i, cell := range row {
			if n := runeLen(cell); n > widths[i] {
				widths[i] = n
			}
		}
	}

	line := make([]string, len(header))
	for i, h := range header {
		line[i] = pad(h, widths[i])
	}
	fmt.Fprintln(w, s.dim(strings.TrimRight(strings.Join(line, "  "), " ")))

	for _, row := range rows {
		cells := make([]string, len(row))
		for i, cell := range row {
			cells[i] = pad(cell, widths[i])
		}
		fmt.Fprintln(w, strings.TrimRight(strings.Join(cells, "  "), " "))
	}
}

// scalar renders a JSON value for a table cell. Strings go in bare — quoting
// every one would make a table of names unreadable — and everything else keeps
// its JSON form, so a number and the string "42" stay distinguishable.
func scalar(v any) string {
	switch value := v.(type) {
	case nil:
		return "null"
	case string:
		return value
	case float64:
		return strconv.FormatFloat(value, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(value)
	default:
		raw, err := json.Marshal(value)
		if err != nil {
			return fmt.Sprint(value)
		}
		return string(raw)
	}
}

// ── small text helpers ──────────────────────────────────────────────────────

func runeLen(s string) int { return len([]rune(s)) }

func pad(s string, width int) string {
	if n := runeLen(s); n < width {
		return s + strings.Repeat(" ", width-n)
	}
	return s
}

func wrap(text string, width int) string {
	words := strings.Fields(text)
	if len(words) == 0 {
		return ""
	}

	var lines []string
	line := words[0]
	for _, word := range words[1:] {
		if runeLen(line)+1+runeLen(word) > width {
			lines = append(lines, line)
			line = word
			continue
		}
		line += " " + word
	}

	return strings.Join(append(lines, line), "\n")
}

func indent(text, with string) string {
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		lines[i] = with + line
	}
	return strings.Join(lines, "\n")
}

func plural(n int, one, many string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, one)
	}
	return fmt.Sprintf("%d %s", n, many)
}

// nameString renders a snapshot name the way it is held: ledger at transaction.
func nameString(name SnapshotName) string {
	if len(name) == 0 {
		return "(no ledgers)"
	}

	ledgers := make([]string, 0, len(name))
	for ledger := range name {
		ledgers = append(ledgers, ledger)
	}
	slices.Sort(ledgers)

	parts := make([]string, 0, len(ledgers))
	for _, ledger := range ledgers {
		parts = append(parts, fmt.Sprintf("%s@%d", ledger, name[ledger]))
	}
	return strings.Join(parts, " ")
}
