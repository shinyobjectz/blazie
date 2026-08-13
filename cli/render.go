package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"slices"
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

// nameString renders a snapshot name the way it is held: world at transaction.
func nameString(name SnapshotName) string {
	if len(name) == 0 {
		return "(no worlds)"
	}

	worlds := make([]string, 0, len(name))
	for world := range name {
		worlds = append(worlds, world)
	}
	slices.Sort(worlds)

	parts := make([]string, 0, len(worlds))
	for _, world := range worlds {
		parts = append(parts, fmt.Sprintf("%s@%d", world, name[world]))
	}
	return strings.Join(parts, " ")
}

// RenderRun prints what a chunk gave back.
//
// The value first, because that is what was asked for. Then the name, because a
// caller holds the name and never the bytes — running the same source at it
// gives this same answer forever, which is the whole reason it is printed at all
// rather than kept for the `--json` path.
func RenderRun(w io.Writer, result *RunResult) {
	s := styleFor(w)

	switch {
	case result.Value == nil:
		fmt.Fprintf(w, "%s\n", s.dim("nil — the chunk returned nothing"))

	case isScalar(result.Value):
		fmt.Fprintf(w, "%v\n", result.Value)

	default:
		// A table comes back as JSON already; indenting is the only thing left
		// to do to it, and printing Go's own map formatting would show a shape
		// nobody sent.
		pretty, err := json.MarshalIndent(result.Value, "", "  ")
		if err != nil {
			fmt.Fprintf(w, "%v\n", result.Value)
		} else {
			fmt.Fprintf(w, "%s\n", pretty)
		}
	}

	wrote := "read only"
	if result.Wrote > 0 {
		wrote = fmt.Sprintf("wrote %d", result.Wrote)
	}
	fmt.Fprintf(w, "%s\n", s.dim(fmt.Sprintf("%s · %s", nameString(result.Name), wrote)))
}

func isScalar(value any) bool {
	switch value.(type) {
	case string, float64, bool, int, int64:
		return true
	default:
		return false
	}
}
