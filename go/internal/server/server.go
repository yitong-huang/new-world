package server

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"os"
	"sync"

	"new.world/nw/internal/protocol"
)

const (
	IPv4HeaderMin = 20
)

// Hub multiplexes one TUN device and many TLS client sessions.
type Hub struct {
	Log *slog.Logger

	mu      sync.RWMutex
	byTunIP map[[4]byte]*Session // dst IPv4 on wire -> session (reply path)
}

func NewHub() *Hub {
	return &Hub{
		Log:     slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo})),
		byTunIP: make(map[[4]byte]*Session),
	}
}

func (h *Hub) Register(s *Session) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.byTunIP[s.TunIP] = s
}

func (h *Hub) Unregister(s *Session) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if cur, ok := h.byTunIP[s.TunIP]; ok && cur == s {
		delete(h.byTunIP, s.TunIP)
	}
}

// RoutePacketToClient sends an IPv4 packet read from TUN to the client whose tun IP equals dst.
func (h *Hub) RoutePacketToClient(pkt []byte) error {
	if len(pkt) < IPv4HeaderMin {
		return nil
	}
	if pkt[0]>>4 != 4 {
		return nil // v6 later
	}
	var dst [4]byte
	copy(dst[:], pkt[16:20])
	h.mu.RLock()
	s := h.byTunIP[dst]
	h.mu.RUnlock()
	if s == nil {
		return nil
	}
	return s.SendData(pkt)
}

type Session struct {
	Hub *Hub
	Log *slog.Logger

	TunIP [4]byte
	conn  net.Conn
	wmu   sync.Mutex // serializes TLS writes
	send  chan []byte // raw IP packets to encode as Data
	done  chan struct{}
}

func NewSession(h *Hub, c net.Conn, tunIP [4]byte) *Session {
	return &Session{
		Hub:   h,
		Log:   h.Log.With("peer", c.RemoteAddr(), "tun_ip", net.IP(tunIP[:]).String()),
		TunIP: tunIP,
		conn:  c,
		send:  make(chan []byte, 256),
		done:  make(chan struct{}),
	}
}

func (s *Session) writeFrame(t protocol.MsgType, payload []byte) error {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	return protocol.WriteFrame(s.conn, t, payload)
}

func (s *Session) SendData(pkt []byte) error {
	select {
	case <-s.done:
		return net.ErrClosed
	case s.send <- append([]byte(nil), pkt...):
		return nil
	default:
		return errors.New("nw: client send queue full")
	}
}

func (s *Session) Close() {
	select {
	case <-s.done:
	default:
		close(s.done)
	}
	_ = s.conn.Close()
}

// PumpToTLS reads IP packets from send queue and writes Data frames to TLS.
func (s *Session) PumpToTLS(ctx context.Context) error {
	defer s.Close()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.done:
			return nil
		case pkt := <-s.send:
			if err := s.writeFrame(protocol.MsgData, pkt); err != nil {
				return err
			}
		}
	}
}

// ReadPump reads frames from TLS: Data -> tunWrite, others handled.
func (s *Session) ReadPump(ctx context.Context, tunWrite func([]byte) error) error {
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		fr, err := protocol.ReadFrame(s.conn)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		switch fr.Type {
		case protocol.MsgData:
			if len(fr.Payload) < IPv4HeaderMin {
				continue
			}
			if fr.Payload[0]>>4 != 4 {
				continue
			}
			var src [4]byte
			copy(src[:], fr.Payload[12:16])
			if src != s.TunIP {
				s.Log.Info("drop spoofed src", "got", net.IP(src[:]).String())
				continue
			}
			if err := tunWrite(fr.Payload); err != nil {
				return err
			}
		case protocol.MsgKeepalive:
			_ = s.writeFrame(protocol.MsgKeepalive, nil)
		case protocol.MsgDisconnect:
			return nil
		default:
			_ = s.writeFrame(protocol.MsgError, protocol.EncodeError(protocol.ErrorBody{
				Code: 1,
				Msg:  "unexpected frame",
			}))
			return errors.New("unexpected frame type")
		}
	}
}
