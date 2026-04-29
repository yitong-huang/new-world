package protocol

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"unicode/utf8"
)

const (
	Magic0 = 'N'
	Magic1 = 'W'
	Magic2 = '0'
	Magic3 = '1'
	Version = 1
	HeaderSize = 12
	MaxPayloadLen = 1<<20 - HeaderSize
)

type MsgType uint8

const (
	MsgClientHello      MsgType = 1
	MsgServerHello      MsgType = 2
	MsgAssignTunnel     MsgType = 3
	MsgData             MsgType = 4
	MsgKeepalive        MsgType = 5
	MsgError            MsgType = 6
	MsgDisconnect       MsgType = 7
	MsgAuthCredentials  MsgType = 8
)

// CapAuthNext in ClientHello.caps: client will send MsgAuthCredentials next (before ServerHello).
const CapAuthNext uint32 = 1 << 1

const maxAuthUTF8Bytes = 512

var ErrBadFrame = errors.New("nw: bad frame")

type Frame struct {
	Type    MsgType
	Payload []byte
}

func EncodeFrame(t MsgType, payload []byte) ([]byte, error) {
	if len(payload) > MaxPayloadLen {
		return nil, fmt.Errorf("%w: payload too large", ErrBadFrame)
	}
	out := make([]byte, HeaderSize+len(payload))
	out[0], out[1], out[2], out[3] = Magic0, Magic1, Magic2, Magic3
	binary.BigEndian.PutUint16(out[4:6], Version)
	out[6] = byte(t)
	out[7] = 0
	binary.BigEndian.PutUint32(out[8:12], uint32(len(payload)))
	copy(out[12:], payload)
	return out, nil
}

func DecodeFrameHeader(prefix []byte) (msgType MsgType, length uint32, err error) {
	if len(prefix) < HeaderSize {
		return 0, 0, io.ErrUnexpectedEOF
	}
	if prefix[0] != Magic0 || prefix[1] != Magic1 || prefix[2] != Magic2 || prefix[3] != Magic3 {
		return 0, 0, ErrBadFrame
	}
	if binary.BigEndian.Uint16(prefix[4:6]) != Version {
		return 0, 0, ErrBadFrame
	}
	if prefix[7] != 0 {
		return 0, 0, ErrBadFrame
	}
	msgType = MsgType(prefix[6])
	length = binary.BigEndian.Uint32(prefix[8:12])
	if length > MaxPayloadLen {
		return 0, 0, ErrBadFrame
	}
	return msgType, length, nil
}

func ReadFrame(r io.Reader) (*Frame, error) {
	var hdr [HeaderSize]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	t, ln, err := DecodeFrameHeader(hdr[:])
	if err != nil {
		return nil, err
	}
	payload := make([]byte, ln)
	if ln > 0 {
		if _, err := io.ReadFull(r, payload); err != nil {
			return nil, err
		}
	}
	return &Frame{Type: t, Payload: payload}, nil
}

func WriteFrame(w io.Writer, t MsgType, payload []byte) error {
	b, err := EncodeFrame(t, payload)
	if err != nil {
		return err
	}
	_, err = w.Write(b)
	return err
}

// --- payloads ---

type ClientHello struct {
	MTU  uint16
	Caps uint32
}

func EncodeClientHello(c ClientHello) []byte {
	b := make([]byte, 6)
	binary.BigEndian.PutUint16(b[0:2], c.MTU)
	binary.BigEndian.PutUint32(b[2:6], c.Caps)
	return b
}

func DecodeClientHello(p []byte) (ClientHello, error) {
	if len(p) < 6 {
		return ClientHello{}, ErrBadFrame
	}
	return ClientHello{
		MTU:  binary.BigEndian.Uint16(p[0:2]),
		Caps: binary.BigEndian.Uint32(p[2:6]),
	}, nil
}

type ServerHello struct {
	MTU  uint16
	Caps uint32
}

func EncodeServerHello(s ServerHello) []byte {
	b := make([]byte, 6)
	binary.BigEndian.PutUint16(b[0:2], s.MTU)
	binary.BigEndian.PutUint32(b[2:6], s.Caps)
	return b
}

func DecodeServerHello(p []byte) (ServerHello, error) {
	if len(p) < 6 {
		return ServerHello{}, ErrBadFrame
	}
	return ServerHello{
		MTU:  binary.BigEndian.Uint16(p[0:2]),
		Caps: binary.BigEndian.Uint32(p[2:6]),
	}, nil
}

type AssignTunnel struct {
	ClientIPv4 [4]byte
	DNSv4      [][4]byte
	Flags      uint8 // bit0 full tunnel
}

func EncodeAssignTunnel(a AssignTunnel) []byte {
	n := len(a.DNSv4)
	if n > 255 {
		n = 255
	}
	out := make([]byte, 4+1+4*n+1)
	copy(out[0:4], a.ClientIPv4[:])
	out[4] = byte(n)
	off := 5
	for i := 0; i < n; i++ {
		copy(out[off:off+4], a.DNSv4[i][:])
		off += 4
	}
	out[off] = a.Flags
	return out
}

func DecodeAssignTunnel(p []byte) (AssignTunnel, error) {
	if len(p) < 4+1+1 {
		return AssignTunnel{}, ErrBadFrame
	}
	var a AssignTunnel
	copy(a.ClientIPv4[:], p[0:4])
	dc := int(p[4])
	if dc > 4 || len(p) < 5+4*dc+1 {
		return AssignTunnel{}, ErrBadFrame
	}
	a.DNSv4 = make([][4]byte, dc)
	for i := 0; i < dc; i++ {
		copy(a.DNSv4[i][:], p[5+4*i:5+4*(i+1)])
	}
	a.Flags = p[5+4*dc]
	return a, nil
}

type ErrorBody struct {
	Code uint16
	Msg  string
}

func EncodeError(e ErrorBody) []byte {
	msg := []byte(e.Msg)
	if len(msg) > 0xffff {
		msg = msg[:0xffff]
	}
	out := make([]byte, 4+len(msg))
	binary.BigEndian.PutUint16(out[0:2], e.Code)
	binary.BigEndian.PutUint16(out[2:4], uint16(len(msg)))
	copy(out[4:], msg)
	return out
}

func DecodeError(p []byte) (ErrorBody, error) {
	if len(p) < 4 {
		return ErrorBody{}, ErrBadFrame
	}
	ml := int(binary.BigEndian.Uint16(p[2:4]))
	if len(p) < 4+ml {
		return ErrorBody{}, ErrBadFrame
	}
	msg := string(p[4 : 4+ml])
	if !utf8.ValidString(msg) {
		return ErrorBody{}, ErrBadFrame
	}
	return ErrorBody{Code: binary.BigEndian.Uint16(p[0:2]), Msg: msg}, nil
}

type DisconnectBody struct {
	Reason uint8
	Msg    string
}

func EncodeDisconnect(d DisconnectBody) []byte {
	msg := []byte(d.Msg)
	if len(msg) > 0xffff {
		msg = msg[:0xffff]
	}
	out := make([]byte, 3+len(msg))
	out[0] = d.Reason
	binary.BigEndian.PutUint16(out[1:3], uint16(len(msg)))
	copy(out[3:], msg)
	return out
}

func DecodeDisconnect(p []byte) (DisconnectBody, error) {
	if len(p) < 3 {
		return DisconnectBody{}, ErrBadFrame
	}
	ml := int(binary.BigEndian.Uint16(p[1:3]))
	if len(p) < 3+ml {
		return DisconnectBody{}, ErrBadFrame
	}
	msg := string(p[3 : 3+ml])
	if !utf8.ValidString(msg) {
		return DisconnectBody{}, ErrBadFrame
	}
	return DisconnectBody{Reason: p[0], Msg: msg}, nil
}

// AuthCredentials (type=8): user_len u16 BE + user UTF-8 + pass_len u16 BE + pass UTF-8.

func EncodeAuthCredentials(user, pass string) ([]byte, error) {
	u := []byte(user)
	p := []byte(pass)
	if len(u) > maxAuthUTF8Bytes || len(p) > maxAuthUTF8Bytes {
		return nil, ErrBadFrame
	}
	out := make([]byte, 2+len(u)+2+len(p))
	binary.BigEndian.PutUint16(out[0:2], uint16(len(u)))
	copy(out[2:], u)
	binary.BigEndian.PutUint16(out[2+len(u):4+len(u)], uint16(len(p)))
	copy(out[4+len(u):], p)
	return out, nil
}

func DecodeAuthCredentials(p []byte) (user, pass string, err error) {
	if len(p) < 4 {
		return "", "", ErrBadFrame
	}
	ul := int(binary.BigEndian.Uint16(p[0:2]))
	if ul < 0 || ul > maxAuthUTF8Bytes || len(p) < 2+ul+2 {
		return "", "", ErrBadFrame
	}
	u := string(p[2 : 2+ul])
	if !utf8.ValidString(u) {
		return "", "", ErrBadFrame
	}
	pl := int(binary.BigEndian.Uint16(p[2+ul : 4+ul]))
	if pl < 0 || pl > maxAuthUTF8Bytes || len(p) < 4+ul+pl {
		return "", "", ErrBadFrame
	}
	pw := string(p[4+ul : 4+ul+pl])
	if !utf8.ValidString(pw) {
		return "", "", ErrBadFrame
	}
	return u, pw, nil
}
