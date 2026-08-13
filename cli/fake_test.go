package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"
)

// The node, faked.
//
// Nothing in this suite opens a socket. A CLI test that reaches the network
// tests the network, and the thing actually worth pinning down here — that a
// repair survives to the terminal, that a slow_down is honoured, that a token
// lands at mode 0600 — needs no node at all.

// recorded is one request as the CLI sent it, kept so a test can assert on the
// shape that went out rather than only on what came back.
type recorded struct {
	Method string
	Path   string
	Header http.Header
	Body   map[string]any
}

// fakeNode answers requests from a script of replies, in order.
type fakeNode struct {
	replies  []reply
	sent     []recorded
	t        *testing.T
	fallback func(*http.Request) reply
}

type reply struct {
	status int
	body   any // marshalled, unless it is a string, which is sent as-is
}

func (f *fakeNode) Do(req *http.Request) (*http.Response, error) {
	record := recorded{Method: req.Method, Path: req.URL.Path, Header: req.Header.Clone()}

	if req.Body != nil {
		raw, err := io.ReadAll(req.Body)
		if err != nil {
			f.t.Fatalf("reading the request body: %v", err)
		}
		if len(raw) > 0 {
			if err := json.Unmarshal(raw, &record.Body); err != nil {
				f.t.Fatalf("the CLI sent something that is not JSON: %s", raw)
			}
		}
	}
	f.sent = append(f.sent, record)

	var next reply
	switch {
	case len(f.replies) > 0:
		next, f.replies = f.replies[0], f.replies[1:]
	case f.fallback != nil:
		next = f.fallback(req)
	default:
		f.t.Fatalf("the CLI made an unexpected %s %s", req.Method, req.URL.Path)
	}

	var raw []byte
	if text, ok := next.body.(string); ok {
		raw = []byte(text)
	} else {
		encoded, err := json.Marshal(next.body)
		if err != nil {
			f.t.Fatalf("encoding the reply: %v", err)
		}
		raw = encoded
	}

	return &http.Response{
		StatusCode: next.status,
		Body:       io.NopCloser(bytes.NewReader(raw)),
		Header:     http.Header{"Content-Type": []string{"application/json"}},
	}, nil
}

// clientWith builds a client against a fake node, with time under the test's
// control: sleeping records the duration and advances the clock, so a polling
// loop that would take fifteen real minutes takes none.
func clientWith(t *testing.T, node *fakeNode) (*Client, *[]time.Duration) {
	t.Helper()
	node.t = t

	slept := []time.Duration{}
	now := time.Unix(1_786_634_000, 0)

	client := &Client{
		BaseURL: "http://node.test",
		Token:   "a-token",
		HTTP:    node,
		Now:     func() time.Time { return now },
	}
	client.Sleep = func(d time.Duration) {
		slept = append(slept, d)
		now = now.Add(d)
	}

	return client, &slept
}

func pending(interval any) reply {
	body := map[string]any{"status": "authorization_pending"}
	if interval != nil {
		body["interval"] = interval
	}
	return reply{status: http.StatusAccepted, body: body}
}

func refused(problem, repair string) reply {
	return reply{
		status: http.StatusUnprocessableEntity,
		body:   map[string]any{"error": map[string]any{"problem": problem, "repair": repair}},
	}
}
