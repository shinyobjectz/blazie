package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

// The polling loop is the part of this CLI most able to be wrong without
// looking wrong: it works against a node that answers immediately and gets
// refused by one under load, and the difference only shows up in production.
// So the cadence is pinned here rather than trusted.

func TestAwaitDeviceHonoursTheStartingInterval(t *testing.T) {
	node := &fakeNode{replies: []reply{
		pending(nil),
		pending(nil),
		{status: http.StatusOK, body: map[string]any{"token": "minted", "login": "shinyobjectz"}},
	}}
	client, slept := clientWith(t, node)

	admitted, err := client.AwaitDevice(context.Background(),
		&DeviceStart{DeviceCode: "d", UserCode: "WDJB-MJHT", Interval: 5, ExpiresIn: 900}, nil)
	if err != nil {
		t.Fatalf("the flow should have completed: %v", err)
	}

	if admitted.Token != "minted" || admitted.Login != "shinyobjectz" {
		t.Fatalf("got %+v", admitted)
	}
	if want := []time.Duration{5 * time.Second, 5 * time.Second}; !sameDurations(*slept, want) {
		t.Fatalf("waited %v, expected %v", *slept, want)
	}
	if len(node.sent) != 3 {
		t.Fatalf("polled %d times, expected 3", len(node.sent))
	}
	if got := node.sent[0].Body["device_code"]; got != "d" {
		t.Fatalf("polled with %v rather than the device code", got)
	}
}

// slow_down reaches this CLI as an ordinary 202 carrying a new interval — the
// node maps GitHub's error onto the pending answer precisely so a client has
// one thing to handle. Adopting it is not optional: GitHub refuses a client
// that keeps hammering at the old cadence.
func TestAwaitDeviceSlowsDownWhenToldTo(t *testing.T) {
	node := &fakeNode{replies: []reply{
		pending(nil),
		pending(10),
		pending(nil),
		{status: http.StatusOK, body: map[string]any{"token": "minted", "login": "shinyobjectz"}},
	}}
	client, slept := clientWith(t, node)

	var changes []time.Duration
	_, err := client.AwaitDevice(context.Background(),
		&DeviceStart{DeviceCode: "d", Interval: 5, ExpiresIn: 900},
		func(d time.Duration, changed bool) {
			if changed {
				changes = append(changes, d)
			}
		})
	if err != nil {
		t.Fatalf("the flow should have completed: %v", err)
	}

	// Five, then ten for the slow_down, then ten again — a null interval on the
	// third answer means "keep going as you are", not "back to the default".
	want := []time.Duration{5 * time.Second, 10 * time.Second, 10 * time.Second}
	if !sameDurations(*slept, want) {
		t.Fatalf("waited %v, expected %v", *slept, want)
	}

	if len(changes) != 1 || changes[0] != 10*time.Second {
		t.Fatalf("the cadence change should have been announced once at 10s, got %v", changes)
	}
}

func TestAwaitDeviceStopsWhenTheCodeExpires(t *testing.T) {
	node := &fakeNode{fallback: func(*http.Request) reply { return pending(nil) }}
	client, _ := clientWith(t, node)

	_, err := client.AwaitDevice(context.Background(),
		&DeviceStart{DeviceCode: "d", UserCode: "WDJB-MJHT", Interval: 5, ExpiresIn: 30}, nil)

	refusal := mustRefusal(t, err)
	if refusal.Problem != "device_flow_expired" {
		t.Fatalf("got problem %q", refusal.Problem)
	}
	if !strings.Contains(refusal.Repair, "blazie login") {
		t.Fatalf("the repair has to say what to do instead, got %q", refusal.Repair)
	}
	// Six five-second waits fit inside thirty seconds; the seventh would not,
	// and the loop must not sit through a wait it knows outlives the code.
	if len(node.sent) > 7 {
		t.Fatalf("polled %d times past a 30 second expiry", len(node.sent))
	}
}

func TestAwaitDeviceCarriesARefusalStraightBack(t *testing.T) {
	node := &fakeNode{replies: []reply{
		pending(nil),
		refused("not_allowed", "shinyobjectz is not allowed to hold a token here. "+
			"Add it to GITHUB_LOGINS if it should be."),
	}}
	client, _ := clientWith(t, node)

	_, err := client.AwaitDevice(context.Background(),
		&DeviceStart{DeviceCode: "d", Interval: 5, ExpiresIn: 900}, nil)

	refusal := mustRefusal(t, err)
	if refusal.Problem != "not_allowed" {
		t.Fatalf("got problem %q", refusal.Problem)
	}
	if !strings.Contains(refusal.Repair, "GITHUB_LOGINS") {
		t.Fatalf("the repair was lost on the way back: %q", refusal.Repair)
	}
	if refusal.Status != http.StatusUnprocessableEntity {
		t.Fatalf("got status %d", refusal.Status)
	}
}

func TestBeginDeviceRefusesAFlowWithNothingToPollWith(t *testing.T) {
	node := &fakeNode{replies: []reply{
		{status: http.StatusOK, body: map[string]any{"user_code": "WDJB-MJHT"}},
	}}
	client, _ := clientWith(t, node)

	_, err := client.BeginDevice(context.Background())

	refusal := mustRefusal(t, err)
	if refusal.Problem != "no_device_code" {
		t.Fatalf("got problem %q", refusal.Problem)
	}
}

func TestBeginDeviceSendsAnObjectRatherThanNothing(t *testing.T) {
	node := &fakeNode{replies: []reply{{status: http.StatusOK, body: map[string]any{
		"device_code": "d", "user_code": "WDJB-MJHT",
		"verification_uri": "https://github.com/login/device",
		"interval":         5, "expires_in": 900,
	}}}}
	client, _ := clientWith(t, node)

	start, err := client.BeginDevice(context.Background())
	if err != nil {
		t.Fatalf("unexpected: %v", err)
	}

	if start.Interval != 5 || start.ExpiresIn != 900 {
		t.Fatalf("got %+v", start)
	}
	// Phoenix parses a JSON body, and a POST with none at all is a different
	// shape to the controller than `{}`.
	if node.sent[0].Body == nil {
		t.Fatal("the CLI sent no body at all")
	}
	if node.sent[0].Header.Get("Content-Type") != "application/json" {
		t.Fatalf("got content type %q", node.sent[0].Header.Get("Content-Type"))
	}
}

func sameDurations(got, want []time.Duration) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

func mustRefusal(t *testing.T, err error) *Refusal {
	t.Helper()
	if err == nil {
		t.Fatal("expected a refusal, got nothing")
	}
	refusal, ok := err.(*Refusal)
	if !ok {
		t.Fatalf("expected a *Refusal, got %T: %v", err, err)
	}
	return refusal
}
