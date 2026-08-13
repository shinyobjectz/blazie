package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/url"
	"strings"
	"testing"
)

// The channel protocol, without a socket underneath it. Everything here is
// about the five-slot array and the one thing that must not be swallowed: a
// join refused for a world this caller may not name.

func TestSocketURLSpeaksVersionTwoAndCarriesTheToken(t *testing.T) {
	got, err := socketURL("http://127.0.0.1:4000", "a-token", nil)
	if err != nil {
		t.Fatal(err)
	}

	parsed, err := url.Parse(got)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Scheme != "ws" || parsed.Path != "/socket/websocket" {
		t.Fatalf("got %s", got)
	}
	// Phoenix defaults an absent version to 1.0.0, whose serializer is an
	// object rather than an array — omitting this parameter silently gets the
	// wrong wire format.
	if parsed.Query().Get("vsn") != "2.0.0" {
		t.Fatalf("got vsn %q", parsed.Query().Get("vsn"))
	}
	if parsed.Query().Get("token") != "a-token" {
		t.Fatalf("got token %q", parsed.Query().Get("token"))
	}
}

func TestSocketURLUpgradesTLS(t *testing.T) {
	got, err := socketURL("https://blazie.example", "t", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(got, "wss://blazie.example/socket/websocket") {
		t.Fatalf("got %s", got)
	}
}

func TestSocketURLRefusesSomethingThatIsNotAnHTTPURL(t *testing.T) {
	_, err := socketURL("ftp://blazie.example", "t", nil)
	refusal := mustRefusal(t, err)
	if !strings.Contains(refusal.Repair, "http://") {
		t.Fatalf("the repair should say what a base URL looks like: %q", refusal.Repair)
	}
}

func TestAChannelMessageRoundTrips(t *testing.T) {
	encoded, err := phxMessage{
		JoinRef: "1", Ref: "1", Topic: watchTopic, Event: "phx_join",
		Payload: json.RawMessage(`{"worlds":["tenant-7"]}`),
	}.encode()
	if err != nil {
		t.Fatal(err)
	}

	// Five slots, in order, as an array. Anything else is the v1 serializer.
	var slots []any
	if err := json.Unmarshal(encoded, &slots); err != nil {
		t.Fatalf("not an array: %s", encoded)
	}
	if len(slots) != 5 {
		t.Fatalf("got %d slots: %s", len(slots), encoded)
	}

	decoded, err := decodePhx(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Topic != watchTopic || decoded.Event != "phx_join" || decoded.JoinRef != "1" {
		t.Fatalf("got %+v", decoded)
	}
}

// A heartbeat has no join_ref, and null is not the same as "".
func TestAHeartbeatSendsNullWhereItHasNoRef(t *testing.T) {
	encoded, err := phxMessage{Ref: "2", Topic: "phoenix", Event: "heartbeat", Payload: []byte("{}")}.encode()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(encoded), `[null,"2","phoenix","heartbeat"`) {
		t.Fatalf("got %s", encoded)
	}
}

func TestDecodeRefusesSomethingThatIsNotFiveSlots(t *testing.T) {
	if _, err := decodePhx([]byte(`["1","1","watch:cli"]`)); err == nil {
		t.Fatal("a three-slot array is not a channel message")
	}
}

// The refusal a join can produce is the one this whole design is about: a
// caller may hold a socket and still not be allowed to name a world.
func TestARefusedJoinCarriesItsRepair(t *testing.T) {
	message := phxMessage{
		JoinRef: "1", Ref: "1", Topic: watchTopic, Event: "phx_reply",
		Payload: json.RawMessage(`{"status":"error","response":{"problem":"not_granted",` +
			`"repair":"This caller may not name \"tenant-7\"."}}`),
	}

	joined := false
	_, err := handleWatchMessage(message, io.Discard, io.Discard, &joined, false)

	refusal := mustRefusal(t, err)
	if refusal.Problem != "not_granted" {
		t.Fatalf("got problem %q", refusal.Problem)
	}
	if !strings.Contains(refusal.Repair, "may not name") {
		t.Fatalf("the repair was lost: %q", refusal.Repair)
	}
}

// A refusal the CLI cannot parse still has to produce something actionable
// rather than an empty problem.
func TestAnUnparseableJoinRefusalStillSaysSomething(t *testing.T) {
	message := phxMessage{
		Topic: watchTopic, Event: "phx_reply",
		Payload: json.RawMessage(`{"status":"error","response":"went wrong"}`),
	}

	joined := false
	_, err := handleWatchMessage(message, io.Discard, io.Discard, &joined, false)

	refusal := mustRefusal(t, err)
	if refusal.Problem != "join_refused" || !strings.Contains(refusal.Repair, "went wrong") {
		t.Fatalf("got %+v", refusal)
	}
}

func TestAJoinSaysWhatItIsWatchingAndThatSilenceIsNormal(t *testing.T) {
	var out, status bytes.Buffer
	joined := false

	message := phxMessage{
		Topic: watchTopic, Event: "phx_reply",
		Payload: json.RawMessage(`{"status":"ok","response":{"watching":["tenant-7"]}}`),
	}
	if _, err := handleWatchMessage(message, &out, &status, &joined, false); err != nil {
		t.Fatal(err)
	}

	if !joined {
		t.Fatal("the join should have been recorded")
	}
	if !strings.Contains(status.String(), "tenant-7") {
		t.Fatalf("got %q", status.String())
	}
	// The channel pushes on change and does not answer at join, so a silent
	// terminal is normal and has to be said, or it reads as a broken socket.
	if !strings.Contains(status.String(), "silence") {
		t.Fatalf("the silence has to be explained: %q", status.String())
	}
}

func TestAnAnswerPrintsWhatTheChunkReturnedAndTheNameItAnsweredAt(t *testing.T) {
	message := phxMessage{
		Topic: watchTopic, Event: "answer",
		Payload: json.RawMessage(`{"name":{"tenant-7":13},"value":[180,175]}`),
	}

	var out bytes.Buffer
	joined := true
	if _, err := handleWatchMessage(message, &out, io.Discard, &joined, false); err != nil {
		t.Fatal(err)
	}

	text := out.String()
	if !strings.Contains(text, "tenant-7@13") {
		t.Fatalf("the snapshot name is what makes an answer cacheable:\n%s", text)
	}
	if !strings.Contains(text, "180") || !strings.Contains(text, "175") {
		t.Fatalf("got:\n%s", text)
	}
}

// --json is one object per line, so a shell reads answers as they arrive rather
// than waiting for a document that never ends.
func TestWatchInJSONIsOneObjectPerLine(t *testing.T) {
	message := phxMessage{
		Topic: watchTopic, Event: "answer",
		Payload: json.RawMessage(`{"name":{"tenant-7":13},"value":[]}`),
	}

	var out bytes.Buffer
	joined := true
	if _, err := handleWatchMessage(message, &out, io.Discard, &joined, true); err != nil {
		t.Fatal(err)
	}

	lines := strings.Split(strings.TrimRight(out.String(), "\n"), "\n")
	if len(lines) != 1 {
		t.Fatalf("expected one line, got %d:\n%s", len(lines), out.String())
	}

	var answer WatchAnswer
	if err := json.Unmarshal([]byte(lines[0]), &answer); err != nil {
		t.Fatalf("the line is not JSON: %v", err)
	}
	if answer.Name["tenant-7"] != 13 {
		t.Fatalf("got %+v", answer)
	}
}

func TestAChannelThatEndsSaysWhatToDo(t *testing.T) {
	joined := true
	done, err := handleWatchMessage(
		phxMessage{Topic: watchTopic, Event: "phx_error", Payload: []byte("{}")},
		io.Discard, io.Discard, &joined, false)

	if !done {
		t.Fatal("a channel error ends the watch")
	}
	refusal := mustRefusal(t, err)
	if !strings.Contains(refusal.Repair, "blazie watch") {
		t.Fatalf("got %q", refusal.Repair)
	}
}

// A heartbeat reply says only that the socket is alive; it is not an answer and
// must not print like one.
func TestAHeartbeatReplyPrintsNothing(t *testing.T) {
	var out, status bytes.Buffer
	joined := false

	done, err := handleWatchMessage(
		phxMessage{Ref: "2", Topic: "phoenix", Event: "phx_reply",
			Payload: json.RawMessage(`{"status":"ok","response":{}}`)},
		&out, &status, &joined, false)

	if err != nil || done {
		t.Fatalf("got done=%v err=%v", done, err)
	}
	if out.Len() != 0 || status.Len() != 0 || joined {
		t.Fatalf("a heartbeat printed %q / %q", out.String(), status.String())
	}
}
