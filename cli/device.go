package main

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

// The device flow, from the terminal's side.
//
// A browser has a redirect to come back to; a terminal has nothing, so it shows
// a human a short code to type somewhere else and then waits. The waiting is
// the whole of the difficulty, and it has two rules that are easy to get wrong:
//
//   - The node names the cadence, not this. `interval` comes back from the
//     start of the flow and can come back AGAIN on any poll, which is how
//     GitHub says slow down. A client that keeps its first interval gets
//     refused outright for hammering.
//
//   - Pending is 202 and not an error. A human still typing is not a failure,
//     and the node answers that way precisely so a CLI does not have to read a
//     message to tell the two apart.

// DeviceStart is what a human has to be shown, and what to poll with.
type DeviceStart struct {
	DeviceCode      string `json:"device_code"`
	UserCode        string `json:"user_code"`
	VerificationURI string `json:"verification_uri"`
	Interval        int    `json:"interval"`
	ExpiresIn       int    `json:"expires_in"`
}

// Admitted is a minted token and who it belongs to.
type Admitted struct {
	Token string `json:"token"`
	Login string `json:"login"`
}

// DevicePoll is one answer from the poll endpoint. Exactly one of Admitted and
// Pending is set.
type DevicePoll struct {
	Admitted *Admitted
	Pending  bool

	// Interval is what the node said the cadence should now be, in seconds, or
	// zero when it did not say. Zero means keep the current one — it is
	// deliberately not "reset to the default", because a slow_down that decayed
	// on the next poll would not be a slow down.
	Interval int
}

// BeginDevice starts a flow. Nothing is recorded until it completes, so
// abandoning one costs nothing and leaves nothing behind.
func (c *Client) BeginDevice(ctx context.Context) (*DeviceStart, error) {
	var start DeviceStart
	if _, err := c.call(ctx, http.MethodPost, "/auth/device", map[string]any{}, &start); err != nil {
		return nil, err
	}

	if start.DeviceCode == "" {
		return nil, &Refusal{
			Problem: "no_device_code",
			Repair: "The node began a device flow without a device code to poll with. " +
				"Check GITHUB_CLIENT_ID is set on it.",
		}
	}

	return &start, nil
}

// PollDevice asks once whether the code has been authorized yet.
func (c *Client) PollDevice(ctx context.Context, deviceCode string) (DevicePoll, error) {
	var body struct {
		Token    string `json:"token"`
		Login    string `json:"login"`
		Status   string `json:"status"`
		Interval *int   `json:"interval"`
	}

	status, err := c.call(ctx, http.MethodPost, "/auth/device/token",
		map[string]any{"device_code": deviceCode}, &body)
	if err != nil {
		return DevicePoll{}, err
	}

	if status == http.StatusAccepted || body.Token == "" {
		poll := DevicePoll{Pending: true}
		if body.Interval != nil && *body.Interval > 0 {
			poll.Interval = *body.Interval
		}
		return poll, nil
	}

	return DevicePoll{Admitted: &Admitted{Token: body.Token, Login: body.Login}}, nil
}

// AwaitDevice polls until the flow completes, is refused, or runs out of time.
//
// onWait is called before each wait with the cadence about to be honoured and
// whether the node has just changed it, so the caller can say "slowing to 10s"
// out loud instead of appearing to hang. It may be nil.
func (c *Client) AwaitDevice(
	ctx context.Context,
	start *DeviceStart,
	onWait func(d time.Duration, changed bool),
) (*Admitted, error) {
	interval := time.Duration(max(start.Interval, 1)) * time.Second

	expires := start.ExpiresIn
	if expires <= 0 {
		expires = 900
	}
	deadline := c.now().Add(time.Duration(expires) * time.Second)

	for {
		poll, err := c.PollDevice(ctx, start.DeviceCode)
		if err != nil {
			return nil, err
		}
		if poll.Admitted != nil {
			return poll.Admitted, nil
		}

		changed := false
		if poll.Interval > 0 {
			if next := time.Duration(poll.Interval) * time.Second; next != interval {
				interval, changed = next, true
			}
		}

		// Checked before waiting rather than after, so an expired flow is named
		// as expired instead of waiting one last cadence to say so.
		if !c.now().Add(interval).Before(deadline) {
			return nil, &Refusal{
				Problem: "device_flow_expired",
				Repair: fmt.Sprintf("The code %s was not authorized within %ds. "+
					"Run `blazie login` again for a fresh one.", start.UserCode, expires),
			}
		}

		if onWait != nil {
			onWait(interval, changed)
		}

		if err := ctx.Err(); err != nil {
			return nil, err
		}
		c.sleep(interval)
	}
}
