package protocol

import (
	"bytes"
	"testing"
)

func TestAuthCredentialsRoundTrip(t *testing.T) {
	b, err := EncodeAuthCredentials("alice", "s3cret")
	if err != nil {
		t.Fatal(err)
	}
	u, p, err := DecodeAuthCredentials(b)
	if err != nil || u != "alice" || p != "s3cret" {
		t.Fatalf("got %q %q err %v", u, p, err)
	}
	fb, err := EncodeFrame(MsgAuthCredentials, b)
	if err != nil {
		t.Fatal(err)
	}
	fr, err := ReadFrame(bytes.NewReader(fb))
	if err != nil || fr.Type != MsgAuthCredentials {
		t.Fatalf("frame %+v err %v", fr, err)
	}
	u2, p2, err := DecodeAuthCredentials(fr.Payload)
	if err != nil || u2 != "alice" || p2 != "s3cret" {
		t.Fatal(u2, p2, err)
	}
}
