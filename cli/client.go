package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// The wire, from this side.
//
// Every refusal this database makes is a 422 carrying a problem and a repair,
// and the repair says how to comply. This file's one job beyond marshalling is
// to make sure that repair survives the trip to a terminal: a CLI that turns
// "grant it, or name only what it holds" into "request failed" has thrown away
// the only part of the answer that was actionable.

// doer is the seam a test replaces. An interface rather than an *http.Client so
// the suite never opens a socket — the tests here answer as the node does.
type doer interface {
	Do(*http.Request) (*http.Response, error)
}

// Client speaks to one node as one caller.
type Client struct {
	BaseURL string
	Token   string
	HTTP    doer

	// Injected so the device-flow loop is testable without waiting in real
	// seconds. Nil means the real thing.
	Sleep func(time.Duration)
	Now   func() time.Time
}

// NewClient builds a client with real time and a real transport.
func NewClient(baseURL, token string) *Client {
	return &Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Token:   token,
		HTTP:    &http.Client{Timeout: 30 * time.Second},
	}
}

func (c *Client) sleep(d time.Duration) {
	if c.Sleep != nil {
		c.Sleep(d)
		return
	}
	time.Sleep(d)
}

func (c *Client) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

// ── refusals ────────────────────────────────────────────────────────────────

// Refusal is a boundary saying no and saying how to comply.
//
// Status is carried alongside because the three that exist mean different
// things to a caller: 401 has no token, 403 has one that may not name what it
// named, 422 sent something the operation could not take.
type Refusal struct {
	Status  int    `json:"-"`
	Problem string `json:"problem"`
	Repair  string `json:"repair"`
}

func (r *Refusal) Error() string {
	if r.Repair == "" {
		return r.Problem
	}
	return r.Problem + ": " + r.Repair
}

// wireRefusal is the envelope refusals arrive in.
type wireRefusal struct {
	Error struct {
		Problem string `json:"problem"`
		Repair  string `json:"repair"`
	} `json:"error"`
}

// ── one request ─────────────────────────────────────────────────────────────

// call sends body to path and unmarshals a 2xx into out.
//
// The 202 the device flow answers with is not a failure, so the status comes
// back for the one caller that cares rather than being flattened into an error.
func (c *Client) call(ctx context.Context, method, path string, body any, out any) (int, error) {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return 0, err
		}
		reader = bytes.NewReader(raw)
	}

	req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, reader)
	if err != nil {
		return 0, &Refusal{
			Problem: "bad_base_url",
			Repair: fmt.Sprintf("%q is not a URL this can send to (%v). Set it with "+
				"--url or BLAZIE_URL.", c.BaseURL, err),
		}
	}

	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "blazie-cli/"+version)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return 0, &Refusal{
			Problem: "unreachable",
			Repair: fmt.Sprintf("Could not reach %s (%v). Check the node is running and that "+
				"--url or BLAZIE_URL points at it.", c.BaseURL, err),
		}
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return resp.StatusCode, &Refusal{
			Problem: "truncated",
			Repair:  fmt.Sprintf("The answer from %s stopped early (%v). Try again.", c.BaseURL, err),
		}
	}

	if resp.StatusCode >= 400 {
		return resp.StatusCode, refusalFrom(resp.StatusCode, raw)
	}

	if out != nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, out); err != nil {
			return resp.StatusCode, &Refusal{
				Problem: "not_json",
				Repair: fmt.Sprintf("%s answered %d with something that is not the JSON this "+
					"expected (%v). Is --url pointing at a blazie node?",
					c.BaseURL, resp.StatusCode, err),
			}
		}
	}

	return resp.StatusCode, nil
}

// refusalFrom recovers the problem and repair, and invents a usable pair when
// the body is not a refusal at all — a proxy's HTML error page reaches here
// too, and "500" on its own tells nobody what to do next.
func refusalFrom(status int, raw []byte) *Refusal {
	var wire wireRefusal
	if err := json.Unmarshal(raw, &wire); err == nil && wire.Error.Problem != "" {
		return &Refusal{Status: status, Problem: wire.Error.Problem, Repair: wire.Error.Repair}
	}

	body := strings.TrimSpace(string(raw))
	if len(body) > 300 {
		body = body[:300] + "…"
	}
	if body == "" {
		body = "(no body)"
	}

	return &Refusal{
		Status:  status,
		Problem: fmt.Sprintf("http_%d", status),
		Repair: fmt.Sprintf("The node answered %d without a repair, which a blazie node does "+
			"not do — so something in front of it answered instead. It said: %s", status, body),
	}
}

// ── who ─────────────────────────────────────────────────────────────────────

// Me is the answer to GET /me: who this token is and what it may name.
type Me struct {
	Login   string   `json:"login"`
	Caller  string   `json:"caller"`
	Ledgers []string `json:"ledgers"`
}

func (c *Client) Me(ctx context.Context) (*Me, error) {
	var me Me
	_, err := c.call(ctx, http.MethodGet, "/me", nil, &me)
	return &me, err
}

// ── the two operations ──────────────────────────────────────────────────────

// SnapshotName is which ledger, at which transaction. A caller holds this and
// never the bytes, which is why an answer can be cached against it forever.
type SnapshotName map[string]int64

// RunResult is what a chunk gave back.
//
// Value is `any` because a chunk returns whatever Lua returns — a number, a
// string, a list, a table. There was a version of this file with a Fact struct
// and a Pattern struct in it; both are gone, because neither is something a
// caller of this CLI has any longer.
type RunResult struct {
	Value any          `json:"value"`
	Name  SnapshotName `json:"name"`
	Wrote int          `json:"wrote"`
}

// RunOptions are the ways to change what a chunk sees.
//
// Name pins the snapshot to read, so the same source at the same name answers
// the same forever. Also widens the world to read; writes land in the ledger
// given to Run and nowhere else. As is "formula" (the default, no clock and no
// network) or "job".
type RunOptions struct {
	Name SnapshotName `json:"name,omitempty"`
	Also []string     `json:"also,omitempty"`
	As   string       `json:"as,omitempty"`
}

// Run sends Lua to a ledger and is given back what it returned.
func (c *Client) Run(ctx context.Context, ledger, source string, opts RunOptions) (*RunResult, error) {
	body := map[string]any{"ledger": ledger, "source": source}
	if opts.Name != nil {
		body["name"] = opts.Name
	}
	if len(opts.Also) > 0 {
		body["also"] = opts.Also
	}
	if opts.As != "" {
		body["as"] = opts.As
	}

	var out RunResult
	_, err := c.call(ctx, http.MethodPost, "/run", body, &out)
	return &out, err
}

// Claim takes a ledger name, which is granted to whoever claimed it.
func (c *Client) Claim(ctx context.Context, ledger string) (SnapshotName, error) {
	var out struct {
		Name SnapshotName `json:"name"`
	}
	_, err := c.call(ctx, http.MethodPost, "/ledgers",
		map[string]any{"ledger": ledger}, &out)
	return out.Name, err
}
