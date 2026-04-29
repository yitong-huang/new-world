package protocol

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func TestEncodeDecodeRoundTrip(t *testing.T) {
	ch := ClientHello{MTU: 1400, Caps: 1}
	b, err := EncodeFrame(MsgClientHello, EncodeClientHello(ch))
	if err != nil {
		t.Fatal(err)
	}
	fr, err := ReadFrame(bytes.NewReader(b))
	if err != nil {
		t.Fatal(err)
	}
	if fr.Type != MsgClientHello {
		t.Fatalf("type %v", fr.Type)
	}
	got, err := DecodeClientHello(fr.Payload)
	if err != nil || got != ch {
		t.Fatalf("got %+v err %v", got, err)
	}
}

func TestGoldenAssignTunnel(t *testing.T) {
	const wantHex = "4e573031000103000000000a0a4d0002010808080801"
	raw, err := hex.DecodeString(wantHex)
	if err != nil {
		t.Fatal(err)
	}
	fr, err := ReadFrame(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	a, err := DecodeAssignTunnel(fr.Payload)
	if err != nil {
		t.Fatal(err)
	}
	if a.ClientIPv4 != [4]byte{10, 77, 0, 2} {
		t.Fatalf("ip %v", a.ClientIPv4)
	}
	if len(a.DNSv4) != 1 || a.DNSv4[0] != [4]byte{8, 8, 8, 8} {
		t.Fatalf("dns %+v", a.DNSv4)
	}
	if a.Flags != 1 {
		t.Fatalf("flags %d", a.Flags)
	}
}
