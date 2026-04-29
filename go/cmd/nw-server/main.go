package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"flag"
	"io"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"time"

	"github.com/songgao/water"

	"new.world/nw/internal/authcfg"
	"new.world/nw/internal/netx"
	"new.world/nw/internal/protocol"
	"new.world/nw/internal/server"
	"new.world/nw/internal/tuntap"
)

func main() {
	addr := flag.String("listen", "0.0.0.0:8443", "TCP listen address")
	cert := flag.String("cert", "certs/server.crt", "TLS certificate PEM")
	key := flag.String("key", "certs/server.key", "TLS key PEM")
	ca := flag.String("client-ca", "", "if set, require client certs signed by this CA PEM")
	ifname := flag.String("ifname", "", "TUN interface name (empty = OS default)")
	cidr := flag.String("tun-cidr", "10.77.0.1/24", "IPv4 assigned to server TUN")
	authFile := flag.String("auth-file", "", "JSON file of users (see configs/auth.server.example.json); if set, ClientHello must be followed by AuthCredentials")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	var authUsers map[string]string
	if *authFile != "" {
		m, err := authcfg.LoadServer(*authFile)
		if err != nil {
			log.Error("load auth-file", "path", *authFile, "err", err)
			os.Exit(1)
		}
		if len(m) == 0 {
			log.Error("auth-file has no users", "path", *authFile)
			os.Exit(1)
		}
		authUsers = m
		log.Info("auth enabled", "users", len(authUsers))
	}

	tun, err := tuntap.Open(*ifname)
	if err != nil {
		log.Error("tun", "err", err)
		os.Exit(1)
	}
	log.Info("tun up", "name", tun.Name())
	if err := tuntap.ConfigureServerIPv4(tun.Name(), *cidr); err != nil {
		log.Error("configure tun", "err", err)
		os.Exit(1)
	}

	certPair, err := tls.LoadX509KeyPair(*cert, *key)
	if err != nil {
		log.Error("load cert", "err", err)
		os.Exit(1)
	}
	tlsCfg := &tls.Config{
		Certificates: []tls.Certificate{certPair},
		MinVersion:   tls.VersionTLS13,
	}
	if *ca != "" {
		b, err := os.ReadFile(*ca)
		if err != nil {
			log.Error("read client ca", "err", err)
			os.Exit(1)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(b) {
			log.Error("parse client ca pem")
			os.Exit(1)
		}
		tlsCfg.ClientAuth = tls.RequireAndVerifyClientCert
		tlsCfg.ClientCAs = pool
	}

	ln, err := tls.Listen("tcp", *addr, tlsCfg)
	if err != nil {
		log.Error("listen", "err", err)
		os.Exit(1)
	}
	log.Info("listening", "addr", *addr)

	hub := server.NewHub()
	hub.Log = log

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	go func() {
		<-ctx.Done()
		_ = ln.Close()
		_ = tun.Close()
	}()

	go tunPump(ctx, log, tun, hub)

	tunW := &lockedWriter{w: tun}

	var nextOctet atomic.Uint32
	nextOctet.Store(1) // Add(1) -> first client gets .2

	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				log.Info("shutdown", "reason", ctx.Err())
				return
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Error("accept", "err", err)
			continue
		}
		go handleClient(ctx, log, hub, tunW, c, &nextOctet, authUsers)
	}
}

type lockedWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (lw *lockedWriter) Write(p []byte) (int, error) {
	lw.mu.Lock()
	defer lw.mu.Unlock()
	return lw.w.Write(p)
}

func tunPump(ctx context.Context, log *slog.Logger, tun *water.Interface, hub *server.Hub) {
	buf := make([]byte, 65535)
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		n, err := tun.Read(buf)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			log.Error("tun read", "err", err)
			return
		}
		if n > 0 {
			pkt := make([]byte, n)
			copy(pkt, buf[:n])
			if err := hub.RoutePacketToClient(pkt); err != nil {
				log.Debug("route to client", "err", err)
			}
		}
	}
}

func handleClient(ctx context.Context, log *slog.Logger, hub *server.Hub, tun io.Writer, raw net.Conn, nextOctet *atomic.Uint32, authUsers map[string]string) {
	defer raw.Close()
	netx.TuneTunnelTransport(raw)
	tc, ok := raw.(*tls.Conn)
	if !ok {
		return
	}
	if err := tc.Handshake(); err != nil {
		log.Error("tls handshake", "err", err)
		return
	}

	requireAuth := len(authUsers) > 0

	fr, err := protocol.ReadFrame(tc)
	if err != nil {
		log.Error("read first frame", "err", err)
		return
	}
	if fr.Type != protocol.MsgClientHello {
		_ = protocol.WriteFrame(tc, protocol.MsgError, protocol.EncodeError(protocol.ErrorBody{Code: 1, Msg: "expected ClientHello"}))
		return
	}
	ch, err := protocol.DecodeClientHello(fr.Payload)
	if err != nil {
		_ = protocol.WriteFrame(tc, protocol.MsgError, protocol.EncodeError(protocol.ErrorBody{Code: 1, Msg: "bad ClientHello"}))
		return
	}
	mtu := ch.MTU
	if mtu == 0 {
		mtu = 1400
	}

	if requireAuth {
		_ = tc.SetReadDeadline(time.Now().Add(30 * time.Second))
		afr, err := protocol.ReadFrame(tc)
		_ = tc.SetReadDeadline(time.Time{})
		if err != nil {
			log.Debug("read auth", "err", err)
			return
		}
		if afr.Type != protocol.MsgAuthCredentials {
			_ = protocol.WriteFrame(tc, protocol.MsgError, protocol.EncodeError(protocol.ErrorBody{Code: 1, Msg: "expected AuthCredentials"}))
			return
		}
		u, p, err := protocol.DecodeAuthCredentials(afr.Payload)
		if err != nil {
			_ = protocol.WriteFrame(tc, protocol.MsgError, protocol.EncodeError(protocol.ErrorBody{Code: 3, Msg: "bad AuthCredentials"}))
			return
		}
		want, ok := authUsers[u]
		if !ok || want != p {
			_ = protocol.WriteFrame(tc, protocol.MsgError, protocol.EncodeError(protocol.ErrorBody{Code: 3, Msg: "authentication failed"}))
			return
		}
	} else if ch.Caps&protocol.CapAuthNext != 0 {
		_ = tc.SetReadDeadline(time.Now().Add(30 * time.Second))
		afr, err := protocol.ReadFrame(tc)
		_ = tc.SetReadDeadline(time.Time{})
		if err != nil {
			log.Debug("read optional auth", "err", err)
			return
		}
		if afr.Type != protocol.MsgAuthCredentials {
			_ = protocol.WriteFrame(tc, protocol.MsgError, protocol.EncodeError(protocol.ErrorBody{Code: 1, Msg: "expected AuthCredentials after CapAuthNext"}))
			return
		}
	}

	if err := protocol.WriteFrame(tc, protocol.MsgServerHello, protocol.EncodeServerHello(protocol.ServerHello{MTU: mtu, Caps: 0})); err != nil {
		return
	}
	idx := nextOctet.Add(1)
	if idx > 250 {
		_ = protocol.WriteFrame(tc, protocol.MsgError, protocol.EncodeError(protocol.ErrorBody{Code: 2, Msg: "pool exhausted"}))
		return
	}
	var ip [4]byte
	ip[0], ip[1], ip[2], ip[3] = 10, 77, 0, byte(idx)
	dns := [][4]byte{{8, 8, 8, 8}}
	assign := protocol.AssignTunnel{ClientIPv4: ip, DNSv4: dns, Flags: 1}
	if err := protocol.WriteFrame(tc, protocol.MsgAssignTunnel, protocol.EncodeAssignTunnel(assign)); err != nil {
		return
	}

	s := server.NewSession(hub, tc, ip)
	s.Log = log.With("peer", tc.RemoteAddr(), "tun_ip", net.IP(ip[:]).String())
	hub.Register(s)
	defer hub.Unregister(s)

	tunWrite := func(pkt []byte) error {
		_, err := tun.Write(pkt)
		return err
	}

	ctxS, cancel := context.WithCancel(ctx)
	defer cancel()
	errCh := make(chan error, 2)
	go func() { errCh <- s.PumpToTLS(ctxS) }()
	go func() { errCh <- s.ReadPump(ctxS, tunWrite) }()
	err = <-errCh
	cancel()
	<-errCh
	if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, net.ErrClosed) {
		log.Debug("session end", "err", err)
	}
}
