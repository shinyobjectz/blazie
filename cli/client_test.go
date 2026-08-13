package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestOpenAskAndWriteSendWhatTheControllerExpects(t *testing.T) {
	node := &fakeNode{replies: []reply{
		{status: 200, body: map[string]any{"name": map[string]any{"tenant-7": 12}}},
		{status: 200, body: map[string]any{"facts": []any{
			map[string]any{"id": 1, "attribute": "height", "value": 180, "tx": 12, "by": nil},
		}}},
		{status: 200, body: map[string]any{"name": map[string]any{"tenant-7": 13}}},
	}}
	client, _ := clientWith(t, node)
	ctx := context.Background()

	name, err := client.Open(ctx, []string{"tenant-7"})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if name["tenant-7"] != 12 {
		t.Fatalf("got %v", name)
	}

	facts, err := client.Ask(ctx, name, Pattern{Attribute: "height"})
	if err != nil {
		t.Fatalf("ask: %v", err)
	}
	if len(facts) != 1 || facts[0].Attribute != "height" || facts[0].Tx != 12 {
		t.Fatalf("got %+v", facts)
	}

	if _, err := client.Write(ctx, "tenant-7", []Assertion{
		{ID: int64(1), Attribute: "height", Value: float64(181)},
	}); err != nil {
		t.Fatalf("write: %v", err)
	}

	if got := node.sent[0].Path; got != "/open" {
		t.Fatalf("open went to %s", got)
	}
	if got := node.sent[1].Path; got != "/ask" {
		t.Fatalf("ask went to %s", got)
	}
	if got := node.sent[2].Path; got != "/write" {
		t.Fatalf("write went to %s", got)
	}

	// The name goes back exactly as it was held, keyed by what each ledger is
	// called. Anything else and the node reopens the wrong transaction.
	askedAt, ok := node.sent[1].Body["name"].(map[string]any)
	if !ok || askedAt["tenant-7"] != float64(12) {
		t.Fatalf("the ask carried %v", node.sent[1].Body["name"])
	}

	// An empty pattern field is absent rather than empty — `{"attribute": ""}`
	// is refused by the node as an attribute that is not a name.
	pattern, _ := node.sent[1].Body["pattern"].(map[string]any)
	if _, present := pattern["value"]; present {
		t.Fatalf("an unasked-for field was sent: %v", pattern)
	}

	// Three wide, always. A fact written from a client names no formula.
	written, _ := node.sent[2].Body["facts"].([]any)
	first, _ := written[0].(map[string]any)
	if _, present := first["by"]; present {
		t.Fatalf("the CLI claimed provenance it cannot have: %v", first)
	}
	if len(first) != 3 {
		t.Fatalf("an assertion is three wide, got %v", first)
	}
}

// `--json` promises what the node said, so a fact that names no formula has to
// come back out as null and not as "". A script telling "produced by nothing"
// from "produced by a formula called nothing" depends on the difference.
func TestANullProducerSurvivesJSON(t *testing.T) {
	node := &fakeNode{replies: []reply{{status: 200, body: map[string]any{"facts": []any{
		map[string]any{"id": 1, "attribute": "height", "value": 180, "tx": 12, "by": nil},
		map[string]any{"id": 2, "attribute": "height", "value": 181, "tx": 12, "by": "$backup"},
	}}}}}
	client, _ := clientWith(t, node)

	facts, err := client.Ask(context.Background(), SnapshotName{"tenant-7": 12}, Pattern{})
	if err != nil {
		t.Fatal(err)
	}

	if facts[0].By != nil {
		t.Fatalf("a fact from outside should keep its null, got %q", *facts[0].By)
	}
	if facts[0].Producer() != "" {
		t.Fatalf("got %q", facts[0].Producer())
	}
	if facts[1].Producer() != "$backup" {
		t.Fatalf("got %q", facts[1].Producer())
	}

	raw, err := json.Marshal(facts[0])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"by":null`) {
		t.Fatalf("null was flattened on the way out: %s", raw)
	}
}

func TestEveryRequestCarriesTheBearerToken(t *testing.T) {
	node := &fakeNode{replies: []reply{{status: 200, body: map[string]any{
		"login": "shinyobjectz", "caller": "abc", "ledgers": []string{"tenant-7"},
	}}}}
	client, _ := clientWith(t, node)

	if _, err := client.Me(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := node.sent[0].Header.Get("Authorization"); got != "Bearer a-token" {
		t.Fatalf("got authorization %q", got)
	}
}

func TestARefusalKeepsItsStatusProblemAndRepair(t *testing.T) {
	node := &fakeNode{replies: []reply{{
		status: http.StatusForbidden,
		body: map[string]any{"error": map[string]any{
			"problem": "not_granted",
			"repair":  `This caller may not name "tenant-7". Grant it, or name only what it holds.`,
		}},
	}}}
	client, _ := clientWith(t, node)

	_, err := client.Open(context.Background(), []string{"tenant-7"})
	refusal := mustRefusal(t, err)

	if refusal.Status != http.StatusForbidden || refusal.Problem != "not_granted" {
		t.Fatalf("got %+v", refusal)
	}
	if !strings.Contains(refusal.Repair, "Grant it") {
		t.Fatalf("the repair was lost: %q", refusal.Repair)
	}
}

// Not everything in front of a node answers the way a node does. A proxy's HTML
// error page reaches here too, and "502" alone tells nobody what to do next.
func TestSomethingThatIsNotANodeStillProducesARepair(t *testing.T) {
	node := &fakeNode{replies: []reply{{status: 502, body: "<html>Bad Gateway</html>"}}}
	client, _ := clientWith(t, node)

	_, err := client.Me(context.Background())
	refusal := mustRefusal(t, err)

	if refusal.Problem != "http_502" {
		t.Fatalf("got problem %q", refusal.Problem)
	}
	if !strings.Contains(refusal.Repair, "Bad Gateway") {
		t.Fatalf("the repair should quote what actually answered: %q", refusal.Repair)
	}
}

func TestAnAnswerThatIsNotJSONSaysSoUsefully(t *testing.T) {
	node := &fakeNode{replies: []reply{{status: 200, body: "not json at all"}}}
	client, _ := clientWith(t, node)

	_, err := client.Me(context.Background())
	refusal := mustRefusal(t, err)

	if refusal.Problem != "not_json" {
		t.Fatalf("got problem %q", refusal.Problem)
	}
	if !strings.Contains(refusal.Repair, "--url") {
		t.Fatalf("the repair should point at the likeliest cause: %q", refusal.Repair)
	}
}

// ── values off a command line ───────────────────────────────────────────────

func TestParseValueGuessesJSONAndCanBeTold(t *testing.T) {
	cases := []struct {
		in    string
		force bool
		want  any
	}{
		{"180", false, float64(180)},
		{"true", false, true},
		{"null", false, nil},
		{`"180"`, false, "180"},
		{"Ada", false, "Ada"},
		{`{"a":1}`, false, map[string]any{"a": float64(1)}},
		{"180", true, "180"},
		{"1.20", true, "1.20"},
	}

	for _, c := range cases {
		got := parseValue(c.in, c.force)
		if !sameJSON(got, c.want) {
			t.Fatalf("parseValue(%q, %v) = %#v, want %#v", c.in, c.force, got, c.want)
		}
	}
}

// An id travels as a number or a string and nothing else, so only whole numbers
// are recognised — a float would be refused at the boundary anyway.
func TestParseIDTakesWholeNumbersOrText(t *testing.T) {
	if got := parseID("42", false); got != int64(42) {
		t.Fatalf("got %#v", got)
	}
	if got := parseID("42", true); got != "42" {
		t.Fatalf("got %#v", got)
	}
	if got := parseID("4.2", false); got != "4.2" {
		t.Fatalf("got %#v", got)
	}
	if got := parseID("person-2", false); got != "person-2" {
		t.Fatalf("got %#v", got)
	}
}

func sameJSON(a, b any) bool {
	am, aok := a.(map[string]any)
	bm, bok := b.(map[string]any)
	if aok != bok {
		return false
	}
	if aok {
		if len(am) != len(bm) {
			return false
		}
		for k, v := range am {
			if !sameJSON(v, bm[k]) {
				return false
			}
		}
		return true
	}
	return a == b
}
