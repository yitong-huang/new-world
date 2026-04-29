package protocol

import (
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type goldenFile struct {
	Frames []goldenFrame `json:"frames"`
}

type goldenFrame struct {
	Name   string          `json:"name"`
	Hex    string          `json:"hex"`
	Expect json.RawMessage `json:"expect"`
}

func goldenJSONPath(t *testing.T) string {
	t.Helper()
	// `go test` cwd is the package directory (…/go/internal/protocol); repo root is three levels up.
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Clean(filepath.Join(wd, "..", "..", "..", "testdata", "golden_frames.json"))
}

func TestGoldenFramesJSON(t *testing.T) {
	p := goldenJSONPath(t)
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Skip("golden file not found:", p, err)
	}
	var gf goldenFile
	if err := json.Unmarshal(raw, &gf); err != nil {
		t.Fatal(err)
	}
	for _, fr := range gf.Frames {
		t.Run(fr.Name, func(t *testing.T) {
			b, err := hex.DecodeString(strings.ReplaceAll(fr.Hex, " ", ""))
			if err != nil {
				t.Fatal(err)
			}
			dec, err := decodeFrameFull(b)
			if err != nil {
				t.Fatal(err)
			}
			var exp struct {
				MsgType       int             `json:"msg_type"`
				ClientHello   json.RawMessage `json:"client_hello"`
				ServerHello   json.RawMessage `json:"server_hello"`
				AssignTunnel  json.RawMessage `json:"assign_tunnel"`
				Error         json.RawMessage `json:"error"`
				Disconnect    json.RawMessage `json:"disconnect"`
			}
			if err := json.Unmarshal(fr.Expect, &exp); err != nil {
				t.Fatal(err)
			}
			if int(dec.Type) != exp.MsgType {
				t.Fatalf("type got %d want %d", dec.Type, exp.MsgType)
			}
			switch dec.Type {
			case MsgClientHello:
				ch, err := DecodeClientHello(dec.Payload)
				if err != nil {
					t.Fatal(err)
				}
				var w struct {
					MTU  uint16 `json:"mtu"`
					Caps uint32 `json:"caps"`
				}
				_ = json.Unmarshal(exp.ClientHello, &w)
				if ch.MTU != w.MTU || ch.Caps != w.Caps {
					t.Fatalf("client_hello %+v vs %+v", ch, w)
				}
			case MsgServerHello:
				sh, err := DecodeServerHello(dec.Payload)
				if err != nil {
					t.Fatal(err)
				}
				var w struct {
					MTU  uint16 `json:"mtu"`
					Caps uint32 `json:"caps"`
				}
				_ = json.Unmarshal(exp.ServerHello, &w)
				if sh.MTU != w.MTU || sh.Caps != w.Caps {
					t.Fatalf("server_hello %+v vs %+v", sh, w)
				}
			case MsgAssignTunnel:
				a, err := DecodeAssignTunnel(dec.Payload)
				if err != nil {
					t.Fatal(err)
				}
				var w struct {
					IPv4  string   `json:"ipv4"`
					DNS   []string `json:"dns"`
					Flags uint8    `json:"flags"`
				}
				_ = json.Unmarshal(exp.AssignTunnel, &w)
				gotIP := net.IP(a.ClientIPv4[:]).String()
				if gotIP != w.IPv4 {
					t.Fatalf("ipv4 got %s want %s", gotIP, w.IPv4)
				}
				if int(a.Flags) != int(w.Flags) {
					t.Fatalf("flags got %d want %d", a.Flags, w.Flags)
				}
				if len(a.DNSv4) != len(w.DNS) {
					t.Fatalf("dns len %d vs %d", len(a.DNSv4), len(w.DNS))
				}
				for i := range a.DNSv4 {
					if net.IP(a.DNSv4[i][:]).String() != w.DNS[i] {
						t.Fatalf("dns %d", i)
					}
				}
			case MsgKeepalive:
			case MsgError:
				e, err := DecodeError(dec.Payload)
				if err != nil {
					t.Fatal(err)
				}
				var w struct {
					Code uint16 `json:"code"`
					Msg  string `json:"msg"`
				}
				_ = json.Unmarshal(exp.Error, &w)
				if e.Code != w.Code || e.Msg != w.Msg {
					t.Fatalf("error %+v vs %+v", e, w)
				}
			case MsgDisconnect:
				d, err := DecodeDisconnect(dec.Payload)
				if err != nil {
					t.Fatal(err)
				}
				var w struct {
					Reason uint8  `json:"reason"`
					Msg    string `json:"msg"`
				}
				_ = json.Unmarshal(exp.Disconnect, &w)
				if d.Reason != w.Reason || d.Msg != w.Msg {
					t.Fatalf("disconnect %+v vs %+v", d, w)
				}
			default:
				t.Fatalf("unhandled type %d", dec.Type)
			}
		})
	}
}

func decodeFrameFull(b []byte) (*Frame, error) {
	if len(b) < HeaderSize {
		return nil, ErrBadFrame
	}
	t, ln, err := DecodeFrameHeader(b)
	if err != nil {
		return nil, err
	}
	if len(b) != HeaderSize+int(ln) {
		return nil, ErrBadFrame
	}
	return &Frame{Type: t, Payload: b[HeaderSize:]}, nil
}
