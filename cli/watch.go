package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// watch — the same question asked again as the snapshot advances.
//
// A Phoenix channel, which is a small protocol on top of the websocket in
// ws.go: every message is a five-element JSON array,
//
//     [join_ref, ref, topic, event, payload]
//
// and that is the whole of the v2 serializer. `vsn=2.0.0` is sent explicitly
// because Phoenix defaults an absent version to 1.0.0, whose serializer is a
// different shape — an object rather than an array — and a client that omits
// the parameter silently gets the older one.
//
// Two things are worth knowing before running this, and are said in the output
// as well as here:
//
//   - The channel pushes when a fact lands inside what the question read. It
//     does not push the current answer at join. A fresh `blazie watch` is
//     therefore silent until something is written, and silence means nothing
//     has changed rather than that the connection is broken.
//
//   - Authorization happens at join, not at connect. A token can hold a socket
//     and still be refused a ledger, and that refusal arrives as a join reply
//     carrying its repair like any other.

const (
	// The topic. Anything after `watch:` is the caller's to choose — the
	// channel matches `watch:*` and ignores the rest.
	watchTopic = "watch:cli"

	// Phoenix's own default, and what phoenix.js sends. The server drops a
	// socket that has said nothing for roughly twice this.
	heartbeatEvery = 30 * time.Second

	// Nothing else is expected inbound between heartbeat replies, so a read
	// that goes this long without one means the socket is gone.
	watchReadTimeout = 3 * heartbeatEvery
)

// WatchAnswer is one push: the facts, and the snapshot name they were answered
// at — so a caller can cache on that name exactly as it would an ask.
type WatchAnswer struct {
	Name  SnapshotName `json:"name"`
	Facts []Fact       `json:"facts"`
}

// socketURL turns the base URL into the websocket endpoint the endpoint mounts.
//
// The token goes in the query string because a websocket handshake from a
// browser cannot set headers, so Phoenix reads connect params from there and
// this speaks the same way the JS client does. It does mean the token can reach
// a proxy's access log, which is the cost of that decision and is stated in the
// README rather than left to be discovered.
func socketURL(baseURL, token string, params url.Values) (string, error) {
	parsed, err := url.Parse(strings.TrimRight(baseURL, "/"))
	if err != nil {
		return "", &Refusal{
			Problem: "bad_base_url",
			Repair:  fmt.Sprintf("%q is not a URL this can open a socket to (%v).", baseURL, err),
		}
	}

	switch parsed.Scheme {
	case "http", "ws":
		parsed.Scheme = "ws"
	case "https", "wss":
		parsed.Scheme = "wss"
	default:
		return "", &Refusal{
			Problem: "bad_base_url",
			Repair: fmt.Sprintf("%q has scheme %q — a base URL has to be http:// or https://.",
				baseURL, parsed.Scheme),
		}
	}

	if params == nil {
		params = url.Values{}
	}
	params.Set("vsn", "2.0.0")
	params.Set("token", token)

	parsed.Path = strings.TrimRight(parsed.Path, "/") + "/socket/websocket"
	parsed.RawQuery = params.Encode()

	return parsed.String(), nil
}

// phxMessage is the five-element array, in and out.
type phxMessage struct {
	JoinRef string
	Ref     string
	Topic   string
	Event   string
	Payload json.RawMessage
}

func (m phxMessage) encode() ([]byte, error) {
	slot := func(s string) any {
		if s == "" {
			return nil
		}
		return s
	}
	return json.Marshal([]any{slot(m.JoinRef), slot(m.Ref), m.Topic, m.Event, json.RawMessage(m.Payload)})
}

func decodePhx(raw []byte) (phxMessage, error) {
	var slots []json.RawMessage
	if err := json.Unmarshal(raw, &slots); err != nil {
		return phxMessage{}, err
	}
	if len(slots) != 5 {
		return phxMessage{}, fmt.Errorf("a channel message has five slots, this had %d", len(slots))
	}

	str := func(raw json.RawMessage) string {
		var s *string
		if err := json.Unmarshal(raw, &s); err != nil || s == nil {
			return ""
		}
		return *s
	}

	return phxMessage{
		JoinRef: str(slots[0]),
		Ref:     str(slots[1]),
		Topic:   str(slots[2]),
		Event:   str(slots[3]),
		Payload: slots[4],
	}, nil
}

// phxReply is the payload of a phx_reply.
type phxReply struct {
	Status   string          `json:"status"`
	Response json.RawMessage `json:"response"`
}

// Watch joins the channel and prints every answer until the context is done or
// the socket drops. It does not reconnect — see the note in the README.
func (c *Client) Watch(ctx context.Context, out, status io.Writer, ledgers []string, pattern Pattern, asJSON bool) error {
	endpoint, err := socketURL(c.BaseURL, c.Token, nil)
	if err != nil {
		return err
	}

	conn, err := wsDial(endpoint, 30*time.Second)
	if err != nil {
		return &Refusal{
			Problem: "socket_refused",
			Repair: fmt.Sprintf("Could not open a websocket to %s (%v). The node must be "+
				"running and reachable, and the token must be one it minted — a socket with "+
				"no token is refused at connect, before any ledger is named.", c.BaseURL, err),
		}
	}
	defer conn.Close()

	// Everything inbound goes through one goroutine, because a socket has one
	// reader by construction and the heartbeat has to be able to write while a
	// read is blocked.
	type inbound struct {
		message phxMessage
		err     error
	}
	messages := make(chan inbound, 8)

	go func() {
		defer close(messages)
		for {
			_ = conn.SetReadDeadline(time.Now().Add(watchReadTimeout))
			_, raw, err := conn.ReadMessage()
			if err != nil {
				messages <- inbound{err: err}
				return
			}
			message, err := decodePhx(raw)
			messages <- inbound{message: message, err: err}
			if err != nil {
				return
			}
		}
	}()

	refs := 0
	nextRef := func() string {
		refs++
		return strconv.Itoa(refs)
	}

	joinPayload, err := json.Marshal(map[string]any{"ledgers": ledgers, "pattern": pattern})
	if err != nil {
		return err
	}

	joinRef := nextRef()
	join := phxMessage{JoinRef: joinRef, Ref: joinRef, Topic: watchTopic, Event: "phx_join", Payload: joinPayload}
	encoded, err := join.encode()
	if err != nil {
		return err
	}
	if err := conn.WriteText(encoded); err != nil {
		return err
	}

	joined := false
	heartbeat := time.NewTicker(heartbeatEvery)
	defer heartbeat.Stop()

	for {
		select {
		case <-ctx.Done():
			return nil

		case <-heartbeat.C:
			beat := phxMessage{Ref: nextRef(), Topic: "phoenix", Event: "heartbeat", Payload: []byte("{}")}
			encoded, err := beat.encode()
			if err != nil {
				return err
			}
			if err := conn.WriteText(encoded); err != nil {
				return &Refusal{
					Problem: "socket_lost",
					Repair: fmt.Sprintf("The socket to %s stopped taking heartbeats (%v). "+
						"Run `blazie watch` again.", c.BaseURL, err),
				}
			}

		case next, open := <-messages:
			if !open {
				return nil
			}
			if next.err != nil {
				return &Refusal{
					Problem: "socket_lost",
					Repair: fmt.Sprintf("The socket to %s ended (%v). Nothing was missed that "+
						"an ask cannot recover — run `blazie watch` again, or ask for the "+
						"facts you want at the snapshot you last saw.", c.BaseURL, next.err),
				}
			}

			done, err := handleWatchMessage(next.message, out, status, &joined, asJSON)
			if err != nil {
				return err
			}
			if done {
				return nil
			}
		}
	}
}

// handleWatchMessage acts on one channel message. Split out so the protocol can
// be tested without a socket underneath it.
func handleWatchMessage(message phxMessage, out, status io.Writer, joined *bool, asJSON bool) (bool, error) {
	s := styleFor(status)

	switch message.Event {
	case "phx_reply":
		var reply phxReply
		if err := json.Unmarshal(message.Payload, &reply); err != nil {
			return false, err
		}

		// Heartbeat replies say only that the socket is alive.
		if message.Topic == "phoenix" {
			return false, nil
		}

		if reply.Status != "ok" {
			var refusal Refusal
			_ = json.Unmarshal(reply.Response, &refusal)
			if refusal.Problem == "" {
				refusal.Problem = "join_refused"
				refusal.Repair = fmt.Sprintf("The channel refused the join and said: %s",
					string(reply.Response))
			}
			return false, &refusal
		}

		if !*joined {
			*joined = true
			var response struct {
				Watching []string `json:"watching"`
			}
			_ = json.Unmarshal(reply.Response, &response)

			if !asJSON {
				fmt.Fprintf(status, "%s %s\n", s.bold("watching"), strings.Join(response.Watching, ", "))
				fmt.Fprintf(status, "%s\n\n", s.dim("answers print as facts land — silence means nothing has changed"))
			}
		}
		return false, nil

	case "answer":
		var answer WatchAnswer
		if err := json.Unmarshal(message.Payload, &answer); err != nil {
			return false, err
		}

		if asJSON {
			// One object per line, so a shell can read this as it arrives
			// rather than waiting for a document that never ends.
			raw, err := json.Marshal(answer)
			if err != nil {
				return false, err
			}
			fmt.Fprintln(out, string(raw))
			return false, nil
		}

		fmt.Fprintf(out, "%s\n", s.dim(nameString(answer.Name)))
		RenderFacts(out, answer.Facts)
		fmt.Fprintln(out)
		return false, nil

	case "phx_error":
		return true, &Refusal{
			Problem: "channel_ended",
			Repair: "The channel stopped on the node's side. Run `blazie watch` again; " +
				"anything written meanwhile is still there to be asked for.",
		}

	case "phx_close":
		return true, nil

	default:
		return false, nil
	}
}
