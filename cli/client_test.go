package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestRunSendsWhatTheControllerExpects(t *testing.T) {
	node := &fakeNode{replies: []reply{
		{status: 200, body: map[string]any{
			"value": float64(180),
			"name":  map[string]any{"tenant-7": 12},
			"wrote": 0,
		}},
	}}
	client, _ := clientWith(t, node)

	result, err := client.Run(context.Background(), "tenant-7", "return ada.height", RunOptions{})
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if result.Value != float64(180) {
		t.Fatalf("got %v", result.Value)
	}
	if result.Name["tenant-7"] != 12 {
		t.Fatalf("got %v", result.Name)
	}

	if got := node.sent[0].Path; got != "/run" {
		t.Fatalf("run went to %s", got)
	}
	if got := node.sent[0].Body["source"]; got != "return ada.height" {
		t.Fatalf("the source arrived as %v", got)
	}

	// Absent rather than empty. `also: []` and `as: ""` are things the node
	// would have to interpret, and there is nothing to interpret them as.
	for _, unasked := range []string{"name", "also", "as"} {
		if _, present := node.sent[0].Body[unasked]; present {
			t.Fatalf("%s was sent without being asked for: %v", unasked, node.sent[0].Body)
		}
	}
}

func TestRunCarriesThePinnedNameWhenThereIsOne(t *testing.T) {
	node := &fakeNode{replies: []reply{{status: 200, body: map[string]any{
		"value": nil, "name": map[string]any{"tenant-7": 12}, "wrote": 0,
	}}}}
	client, _ := clientWith(t, node)

	_, err := client.Run(context.Background(), "tenant-7", "return 1", RunOptions{
		Name: SnapshotName{"tenant-7": 12},
		Also: []string{"shared"},
		As:   "job",
	})
	if err != nil {
		t.Fatal(err)
	}

	// The name goes back exactly as it was held, keyed by what each world is
	// called. Anything else and the node reopens the wrong transaction.
	pinned, ok := node.sent[0].Body["name"].(map[string]any)
	if !ok || pinned["tenant-7"] != float64(12) {
		t.Fatalf("the run carried %v", node.sent[0].Body["name"])
	}
	if node.sent[0].Body["as"] != "job" {
		t.Fatalf("as arrived as %v", node.sent[0].Body["as"])
	}
	also, _ := node.sent[0].Body["also"].([]any)
	if len(also) != 1 || also[0] != "shared" {
		t.Fatalf("also arrived as %v", node.sent[0].Body["also"])
	}
}

// A chunk returns whatever Lua returns, so the client cannot assume a shape.
func TestRunTakesAnyShapeBack(t *testing.T) {
	for _, value := range []any{
		float64(180),
		"Ada",
		true,
		[]any{float64(1), float64(2)},
		map[string]any{"id": "ada", "height": float64(180)},
		nil,
	} {
		node := &fakeNode{replies: []reply{{status: 200, body: map[string]any{
			"value": value, "name": map[string]any{"t": 1}, "wrote": 0,
		}}}}
		client, _ := clientWith(t, node)

		result, err := client.Run(context.Background(), "t", "return x", RunOptions{})
		if err != nil {
			t.Fatalf("%v: %v", value, err)
		}
		if got, _ := json.Marshal(result.Value); string(got) != mustJSON(value) {
			t.Fatalf("got %s, want %s", got, mustJSON(value))
		}
	}
}

func TestClaimTakesAName(t *testing.T) {
	node := &fakeNode{replies: []reply{{status: 201, body: map[string]any{
		"world": "orders", "name": map[string]any{"orders": 0},
	}}}}
	client, _ := clientWith(t, node)

	if _, err := client.Claim(context.Background(), "orders"); err != nil {
		t.Fatal(err)
	}
	if got := node.sent[0].Path; got != "/worlds" {
		t.Fatalf("claim went to %s", got)
	}
	if got := node.sent[0].Body["world"]; got != "orders" {
		t.Fatalf("claim carried %v", got)
	}
}

func mustJSON(value any) string {
	raw, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return string(raw)
}

func TestEveryRequestCarriesTheBearerToken(t *testing.T) {
	node := &fakeNode{replies: []reply{{status: 200, body: map[string]any{
		"login": "shinyobjectz", "caller": "abc", "worlds": []string{"tenant-7"},
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

	_, err := client.Run(context.Background(), "tenant-7", "return 1", RunOptions{})
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
