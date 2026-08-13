package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

// The websocket is written by hand, so the frame format is pinned here. The
// rule that bites: a client MUST mask every frame it sends, and a conforming
// server drops the connection on an unmasked one — which looks exactly like a
// network fault from this side and is therefore worth a test rather than a
// debugging session.

func TestClientFramesAreAlwaysMasked(t *testing.T) {
	frame, err := encodeFrame(opText, []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}

	if frame[0] != 0x81 {
		t.Fatalf("expected a final text frame, got %#x", frame[0])
	}
	if frame[1]&0x80 == 0 {
		t.Fatalf("the mask bit is not set: %#x", frame[1])
	}
	if length := frame[1] & 0x7F; length != 5 {
		t.Fatalf("got length %d", length)
	}

	mask := frame[2:6]
	unmasked := make([]byte, 5)
	for i, b := range frame[6:] {
		unmasked[i] = b ^ mask[i%4]
	}
	if string(unmasked) != "hello" {
		t.Fatalf("got %q", unmasked)
	}
}

func TestFrameLengthsUseTheRightWidth(t *testing.T) {
	short, _ := encodeFrame(opText, bytes.Repeat([]byte("x"), 125))
	if short[1]&0x7F != 125 {
		t.Fatalf("125 bytes should be inline, got %d", short[1]&0x7F)
	}

	medium, _ := encodeFrame(opText, bytes.Repeat([]byte("x"), 300))
	if medium[1]&0x7F != 126 {
		t.Fatalf("300 bytes should use the 16-bit length, got %d", medium[1]&0x7F)
	}
	if got := binary.BigEndian.Uint16(medium[2:4]); got != 300 {
		t.Fatalf("got length %d", got)
	}

	long, _ := encodeFrame(opText, bytes.Repeat([]byte("x"), 70_000))
	if long[1]&0x7F != 127 {
		t.Fatalf("70000 bytes should use the 64-bit length, got %d", long[1]&0x7F)
	}
	if got := binary.BigEndian.Uint64(long[2:10]); got != 70_000 {
		t.Fatalf("got length %d", got)
	}
}

func TestAcceptKeyIsTheOneFromTheRFC(t *testing.T) {
	// The worked example in RFC 6455 §1.3, which is the whole point of the
	// check: a 101 from something that is not a websocket server fails it.
	if got := acceptKey("dGhlIHNhbXBsZSBub25jZQ=="); got != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" {
		t.Fatalf("got %q", got)
	}
}

// Reading reassembles continuation frames and answers pings on the way, so a
// caller only ever sees whole messages.
func TestReadMessageReassemblesAndAnswersPings(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	conn := &wsConn{conn: client, br: bufio.NewReader(client)}

	// net.Pipe is unbuffered, so the pong the client owes has to be read by
	// somebody concurrently or both ends block on each other.
	go func() { io.Copy(io.Discard, server) }()

	go func() {
		// A ping mid-message, then the two halves of one text message. Server
		// frames are unmasked, as a server's must be.
		server.Write(serverFrame(true, opPing, []byte("are you there")))
		server.Write(serverFrame(false, opText, []byte(`["1",`)))
		server.Write(serverFrame(true, opContinuation, []byte(`null,"t","e",{}]`)))
	}()

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	opcode, payload, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("reading: %v", err)
	}
	if opcode != opText {
		t.Fatalf("got opcode %#x", opcode)
	}
	if string(payload) != `["1",null,"t","e",{}]` {
		t.Fatalf("got %q", payload)
	}
}

func TestAServerCloseEndsTheRead(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	conn := &wsConn{conn: client, br: bufio.NewReader(client)}

	go func() {
		server.Write(serverFrame(true, opClose, []byte{0x03, 0xE8}))
		io.Copy(io.Discard, server)
	}()

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, _, err := conn.ReadMessage(); err != io.EOF {
		t.Fatalf("a close should end the read, got %v", err)
	}
}

// serverFrame builds an unmasked frame, the way a server sends one.
func serverFrame(fin bool, opcode byte, payload []byte) []byte {
	header := []byte{opcode}
	if fin {
		header[0] |= 0x80
	}

	switch {
	case len(payload) < 126:
		header = append(header, byte(len(payload)))
	default:
		header = append(header, 126, 0, 0)
		binary.BigEndian.PutUint16(header[2:], uint16(len(payload)))
	}

	return append(header, payload...)
}
