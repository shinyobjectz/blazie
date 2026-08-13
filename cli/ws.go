package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"
)

// A websocket client, by hand.
//
// Why not a library: this binary's entire promise is `brew install blazie` — one
// file, no runtime, nothing to fetch. Every dependency is a supply chain to
// audit and a version to keep, and what `watch` actually needs of RFC 6455 is
// small and closed: an HTTP upgrade, text frames in both directions, masking on
// the way out, and ping answered with pong. That is the code below. It does not
// do compression, subprotocols, or fragmented writes, and it says so here
// rather than failing mysteriously if any of those ever start mattering.
//
// The one rule that bites people: a client MUST mask every frame it sends and a
// server MUST NOT mask anything it sends. A conforming server closes the
// connection on an unmasked client frame, which looks exactly like a network
// fault from this side.

const (
	opContinuation = 0x0
	opText         = 0x1
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xA

	// From RFC 6455. Concatenated with the client key to prove the server
	// actually spoke websocket rather than merely answering 101.
	wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

	// A frame larger than this is not something this protocol sends us, and
	// accepting an arbitrary length off the wire is how a client is made to
	// allocate a machine's memory on request.
	maxFrameBytes = 8 << 20
)

// wsConn is one open websocket.
type wsConn struct {
	conn net.Conn
	br   *bufio.Reader

	// Writes are serialised because the heartbeat and the caller both send, and
	// two interleaved frames on one connection is a protocol violation rather
	// than a race that merely reorders.
	writeMu sync.Mutex
	closed  bool
}

// wsDial performs the HTTP upgrade and hands back an open socket.
func wsDial(rawURL string, timeout time.Duration) (*wsConn, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("%q is not a URL: %w", rawURL, err)
	}

	var secure bool
	switch parsed.Scheme {
	case "ws":
	case "wss":
		secure = true
	default:
		return nil, fmt.Errorf("%q is not a websocket URL — expected ws:// or wss://", rawURL)
	}

	host := parsed.Host
	if parsed.Port() == "" {
		if secure {
			host = net.JoinHostPort(parsed.Hostname(), "443")
		} else {
			host = net.JoinHostPort(parsed.Hostname(), "80")
		}
	}

	dialer := &net.Dialer{Timeout: timeout}

	var conn net.Conn
	if secure {
		conn, err = tls.DialWithDialer(dialer, "tcp", host, &tls.Config{ServerName: parsed.Hostname()})
	} else {
		conn, err = dialer.Dial("tcp", host)
	}
	if err != nil {
		return nil, err
	}

	key := make([]byte, 16)
	if _, err := rand.Read(key); err != nil {
		conn.Close()
		return nil, err
	}
	encodedKey := base64.StdEncoding.EncodeToString(key)

	path := parsed.RequestURI()
	request := "GET " + path + " HTTP/1.1\r\n" +
		"Host: " + parsed.Host + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + encodedKey + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"User-Agent: blazie-cli/" + version + "\r\n\r\n"

	_ = conn.SetWriteDeadline(time.Now().Add(timeout))
	if _, err := io.WriteString(conn, request); err != nil {
		conn.Close()
		return nil, err
	}
	_ = conn.SetWriteDeadline(time.Time{})

	br := bufio.NewReader(conn)
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	resp, err := http.ReadResponse(br, &http.Request{Method: http.MethodGet})
	if err != nil {
		conn.Close()
		return nil, err
	}
	_ = conn.SetReadDeadline(time.Time{})

	if resp.StatusCode != http.StatusSwitchingProtocols {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		conn.Close()
		return nil, fmt.Errorf("the node answered %d rather than upgrading: %s",
			resp.StatusCode, string(body))
	}

	if got, want := resp.Header.Get("Sec-WebSocket-Accept"), acceptKey(encodedKey); got != want {
		conn.Close()
		return nil, errors.New("the upgrade was accepted with the wrong key — " +
			"whatever answered is not speaking websocket")
	}

	return &wsConn{conn: conn, br: br}, nil
}

func acceptKey(clientKey string) string {
	sum := sha1.Sum([]byte(clientKey + wsGUID))
	return base64.StdEncoding.EncodeToString(sum[:])
}

// ReadMessage returns the next complete application message, answering pings
// and following close frames on the way. Continuation frames are reassembled
// here so a caller only ever sees whole messages.
func (c *wsConn) ReadMessage() (opcode byte, payload []byte, err error) {
	var (
		assembling bool
		first      byte
		buffer     []byte
	)

	for {
		frame, err := c.readFrame()
		if err != nil {
			return 0, nil, err
		}

		switch frame.opcode {
		case opPing:
			if err := c.writeFrame(opPong, frame.payload); err != nil {
				return 0, nil, err
			}
			continue

		case opPong:
			continue

		case opClose:
			// Echo the close and stop. The status code, if any, is the first
			// two bytes; it is not worth surfacing separately because every
			// close this client can get means the same thing to a caller.
			_ = c.writeFrame(opClose, frame.payload)
			c.Close()
			return 0, nil, io.EOF

		case opContinuation:
			if !assembling {
				return 0, nil, errors.New("a continuation frame arrived with nothing to continue")
			}
			buffer = append(buffer, frame.payload...)

		case opText, opBinary:
			if assembling {
				return 0, nil, errors.New("a new message began before the last one finished")
			}
			assembling = true
			first = frame.opcode
			buffer = frame.payload

		default:
			return 0, nil, fmt.Errorf("unknown websocket opcode %#x", frame.opcode)
		}

		if frame.fin && assembling {
			return first, buffer, nil
		}
		if len(buffer) > maxFrameBytes {
			return 0, nil, errors.New("a websocket message grew past what this will hold")
		}
	}
}

// WriteText sends one text frame.
func (c *wsConn) WriteText(payload []byte) error {
	return c.writeFrame(opText, payload)
}

// Close sends a close frame and drops the connection. Safe to call twice, which
// matters because both the reader and a deferred close reach for it.
func (c *wsConn) Close() error {
	c.writeMu.Lock()
	already := c.closed
	c.closed = true
	c.writeMu.Unlock()

	if already {
		return nil
	}

	_ = c.writeFrame(opClose, []byte{0x03, 0xE8}) // 1000, a normal close.
	return c.conn.Close()
}

// SetReadDeadline bounds a read, so a socket that has silently died is noticed
// rather than waited on forever.
func (c *wsConn) SetReadDeadline(t time.Time) error { return c.conn.SetReadDeadline(t) }

// ── frames ──────────────────────────────────────────────────────────────────

type wsFrame struct {
	fin     bool
	opcode  byte
	payload []byte
}

func (c *wsConn) readFrame() (wsFrame, error) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(c.br, header); err != nil {
		return wsFrame{}, err
	}

	frame := wsFrame{
		fin:    header[0]&0x80 != 0,
		opcode: header[0] & 0x0F,
	}

	masked := header[1]&0x80 != 0
	length := uint64(header[1] & 0x7F)

	switch length {
	case 126:
		extended := make([]byte, 2)
		if _, err := io.ReadFull(c.br, extended); err != nil {
			return wsFrame{}, err
		}
		length = uint64(binary.BigEndian.Uint16(extended))
	case 127:
		extended := make([]byte, 8)
		if _, err := io.ReadFull(c.br, extended); err != nil {
			return wsFrame{}, err
		}
		length = binary.BigEndian.Uint64(extended)
	}

	if length > maxFrameBytes {
		return wsFrame{}, fmt.Errorf("a %d byte frame is larger than this client will hold", length)
	}

	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(c.br, mask[:]); err != nil {
			return wsFrame{}, err
		}
	}

	frame.payload = make([]byte, length)
	if _, err := io.ReadFull(c.br, frame.payload); err != nil {
		return wsFrame{}, err
	}

	if masked {
		for i := range frame.payload {
			frame.payload[i] ^= mask[i%4]
		}
	}

	return frame, nil
}

func (c *wsConn) writeFrame(opcode byte, payload []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	frame, err := encodeFrame(opcode, payload)
	if err != nil {
		return err
	}

	_ = c.conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
	_, err = c.conn.Write(frame)
	_ = c.conn.SetWriteDeadline(time.Time{})
	return err
}

// encodeFrame builds one masked, unfragmented frame. Split out from writeFrame
// so the wire format can be tested without a socket.
func encodeFrame(opcode byte, payload []byte) ([]byte, error) {
	var mask [4]byte
	if _, err := rand.Read(mask[:]); err != nil {
		return nil, err
	}

	length := len(payload)
	header := []byte{0x80 | opcode}

	switch {
	case length < 126:
		header = append(header, 0x80|byte(length))
	case length <= 0xFFFF:
		header = append(header, 0x80|126, 0, 0)
		binary.BigEndian.PutUint16(header[2:], uint16(length))
	default:
		header = append(header, 0x80|127, 0, 0, 0, 0, 0, 0, 0, 0)
		binary.BigEndian.PutUint64(header[2:], uint64(length))
	}

	frame := append(header, mask[:]...)
	masked := make([]byte, length)
	for i, b := range payload {
		masked[i] = b ^ mask[i%4]
	}

	return append(frame, masked...), nil
}
