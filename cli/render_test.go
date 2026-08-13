package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// A boundary that rejects without saying how to comply produces loops rather
// than compliance. That is doctrine on the node's side, and it is only true on
// this side if the repair reaches the terminal — so these tests are about the
// repair and nothing else.

func TestRenderRefusalPrintsTheRepair(t *testing.T) {
	var out bytes.Buffer

	RenderRefusal(&out, &Refusal{
		Status:  403,
		Problem: "not_granted",
		Repair:  `This caller may not name "tenant-7". Grant it, or name only what it holds.`,
	})

	text := out.String()
	if !strings.Contains(text, "not_granted") {
		t.Fatalf("the problem is missing:\n%s", text)
	}
	// Compared with whitespace collapsed, because the repair is wrapped to the
	// terminal and the words are what has to survive, not the line breaks.
	flat := strings.Join(strings.Fields(text), " ")
	if !strings.Contains(flat, "Grant it, or name only what it holds.") {
		t.Fatalf("the repair is missing, which is the only part that was actionable:\n%s", text)
	}
	if !strings.Contains(text, "403") {
		t.Fatalf("the status is missing:\n%s", text)
	}
	// On its own line and indented — a repair buried at the end of a sentence
	// is a repair somebody skims past.
	if !strings.Contains(text, "\n    This caller may not name") {
		t.Fatalf("the repair should stand on its own indented line:\n%s", text)
	}
}

// Long repairs are wrapped rather than run off the edge, and every word of the
// repair survives the wrapping.
func TestRenderRefusalWrapsWithoutLosingWords(t *testing.T) {
	repair := "A written fact came from outside and names no formula. Drop `by` — if this " +
		"value was derived, declare the formula that derives it and let it produce the fact."

	var out bytes.Buffer
	RenderRefusal(&out, &Refusal{Status: 422, Problem: "cannot_claim_derivation", Repair: repair})

	printed := strings.Join(strings.Fields(out.String()), " ")
	if !strings.Contains(printed, strings.Join(strings.Fields(repair), " ")) {
		t.Fatalf("wrapping dropped part of the repair:\n%s", out.String())
	}
	for _, line := range strings.Split(out.String(), "\n") {
		if len([]rune(line)) > 78 {
			t.Fatalf("a line ran to %d columns: %q", len([]rune(line)), line)
		}
	}
}

// A refusal without a repair is the node breaking its own rule. Said out loud,
// because the person seeing it is the only one who can report it.
func TestRenderRefusalNamesAMissingRepair(t *testing.T) {
	var out bytes.Buffer
	RenderRefusal(&out, &Refusal{Status: 500, Problem: "boom"})

	if !strings.Contains(out.String(), "no repair") {
		t.Fatalf("a repairless refusal should say so:\n%s", out.String())
	}
}

func TestRenderRefusalHandlesAPlainError(t *testing.T) {
	var out bytes.Buffer
	RenderRefusal(&out, errors.New("the disk went away"))

	if !strings.Contains(out.String(), "the disk went away") {
		t.Fatalf("got:\n%s", out.String())
	}
}

// --json has to carry the repair too. A script that retries on the wrong thing
// is the same loop this design exists to prevent, one layer out.
func TestRenderRefusalJSONKeepsProblemAndRepair(t *testing.T) {
	var out bytes.Buffer
	RenderRefusalJSON(&out, &Refusal{
		Status: 422, Problem: "unknown_attribute", Repair: "An attribute is a non-empty name.",
	})

	var decoded struct {
		Error struct {
			Problem string `json:"problem"`
			Repair  string `json:"repair"`
		} `json:"error"`
	}
	if err := json.Unmarshal(out.Bytes(), &decoded); err != nil {
		t.Fatalf("--json produced something unparseable: %v\n%s", err, out.String())
	}
	if decoded.Error.Problem != "unknown_attribute" {
		t.Fatalf("got %+v", decoded.Error)
	}
	if decoded.Error.Repair != "An attribute is a non-empty name." {
		t.Fatalf("got %+v", decoded.Error)
	}
}

func TestRenderRefusalJSONWrapsAPlainError(t *testing.T) {
	var out bytes.Buffer
	RenderRefusalJSON(&out, errors.New("the disk went away"))

	if !strings.Contains(out.String(), "cli_failed") ||
		!strings.Contains(out.String(), "the disk went away") {
		t.Fatalf("got:\n%s", out.String())
	}
}

// ── facts ───────────────────────────────────────────────────────────────────

func TestRenderFactsKeepsTypesDistinguishable(t *testing.T) {
	var out bytes.Buffer
	RenderFacts(&out, []Fact{
		{ID: float64(1), Attribute: "height", Value: float64(180), Tx: 7},
		{ID: "person-2", Attribute: "name", Value: "Ada", Tx: 8, By: strPtr("$backup")},
		{ID: float64(3), Attribute: "known", Value: true, Tx: 9},
	})

	text := out.String()
	for _, want := range []string{"height", "180", "person-2", "Ada", "true", "$backup", "3 facts"} {
		if !strings.Contains(text, want) {
			t.Fatalf("%q is missing:\n%s", want, text)
		}
	}
	// A fact with no `by` came from outside, and the column says so rather than
	// going blank — provenance is why the column is there.
	if !strings.Contains(text, "—") {
		t.Fatalf("a fact from outside should be marked, not left blank:\n%s", text)
	}
}

func TestRenderFactsSaysWhenNothingAnswers(t *testing.T) {
	var out bytes.Buffer
	RenderFacts(&out, nil)

	if !strings.Contains(out.String(), "no facts") {
		t.Fatalf("got:\n%s", out.String())
	}
}

func TestNameStringIsStableAndReadable(t *testing.T) {
	got := nameString(SnapshotName{"tenant-7": 12, "$identities": 3})
	if got != "$identities@3 tenant-7@12" {
		t.Fatalf("got %q", got)
	}
	if nameString(nil) != "(no ledgers)" {
		t.Fatalf("got %q", nameString(nil))
	}
}

// ── the user code ───────────────────────────────────────────────────────────

func TestBigTypeRendersACodeAndRefusesWhatItCannotDraw(t *testing.T) {
	big := BigType("WDJB-MJHT")
	if big == "" {
		t.Fatal("a GitHub device code should render")
	}
	if lines := strings.Split(big, "\n"); len(lines) != bigTypeRows {
		t.Fatalf("got %d rows", len(lines))
	}

	// A missing glyph would leave a hole in a code somebody has to type, so the
	// whole thing falls back to plain text instead.
	if BigType("code!") != "" {
		t.Fatal("an undrawable character should fall back rather than leave a gap")
	}
}

func TestWriteUserCodeAlwaysPrintsThePlainCodeToo(t *testing.T) {
	var out bytes.Buffer
	WriteUserCode(&out, "WDJB-MJHT")

	if !strings.Contains(out.String(), "WDJB-MJHT") {
		t.Fatalf("the code has to be selectable as text:\n%s", out.String())
	}
}
