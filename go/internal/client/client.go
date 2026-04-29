package client

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"

	"new.world/nw/internal/netx"
	"new.world/nw/internal/protocol"
	"new.world/nw/internal/tuntap"
)

// Run connects with TLS, completes NW handshake, then relays IPv4 between tun and conn.
// If authUser is non-empty, sends AuthCredentials after ClientHello (and sets CapAuthNext in ClientHello).
// setup is called once after AssignTunnel with the TUN interface name (for ip/ifconfig).
// tunRelease, if non-nil, is called on SIGINT (ctx done) and after one relay pump exits, to unblock
// the other pump’s blocking Read (typically closes the TUN); must be safe to call multiple times (e.g. sync.Once).
func Run(ctx context.Context, log *slog.Logger, tlsCfg *tls.Config, serverAddr string, tunName string, tunReadWriter interface {
	io.Reader
	io.Writer
}, authUser, authPass string, setup func(ifName, clientIP, serverIP string) error, splitDefault func(ifName string) (cleanup func(), err error), tunRelease func()) error {
	var bypassCleanup func()
	var splitCleanup func()
	defer func() {
		if splitCleanup != nil {
			splitCleanup()
		}
		if bypassCleanup != nil {
			bypassCleanup()
		}
	}()

	nd := &net.Dialer{}
	tcpConn, err := nd.DialContext(ctx, "tcp", serverAddr)
	if err != nil {
		return err
	}
	netx.TuneTunnelTransport(tcpConn)
	raw := tls.Client(tcpConn, tlsCfg)
	if err := raw.HandshakeContext(ctx); err != nil {
		_ = raw.Close()
		return err
	}
	defer raw.Close()
	conn := raw

	var caps uint32
	if authUser != "" {
		caps |= protocol.CapAuthNext
	}
	if err := writeFrameSafe(conn, protocol.MsgClientHello, protocol.EncodeClientHello(protocol.ClientHello{MTU: uint16(tuntap.ClientIPv4MTU), Caps: caps})); err != nil {
		return err
	}
	if authUser != "" {
		ap, err := protocol.EncodeAuthCredentials(authUser, authPass)
		if err != nil {
			return err
		}
		if err := writeFrameSafe(conn, protocol.MsgAuthCredentials, ap); err != nil {
			return err
		}
	}
	fr, err := readFrameSafe(conn)
	if err != nil {
		return err
	}
	if fr.Type == protocol.MsgError {
		eb, _ := protocol.DecodeError(fr.Payload)
		return fmt.Errorf("nw: server error %d: %s", eb.Code, eb.Msg)
	}
	if fr.Type != protocol.MsgServerHello {
		return errors.New("nw: expected ServerHello")
	}
	sh, err := protocol.DecodeServerHello(fr.Payload)
	if err != nil {
		return err
	}
	_ = sh
	fr, err = readFrameSafe(conn)
	if err != nil {
		return err
	}
	if fr.Type != protocol.MsgAssignTunnel {
		return errors.New("nw: expected AssignTunnel")
	}
	assign, err := protocol.DecodeAssignTunnel(fr.Payload)
	if err != nil {
		return err
	}
	clientIP := net.IP(assign.ClientIPv4[:]).String()
	serverIP := "10.77.0.1"
	if setup != nil {
		if err := setup(tunName, clientIP, serverIP); err != nil {
			log.Error("tun setup", "err", err)
			return err
		}
	}
	if splitDefault != nil {
		// 避免 0.0.0.0/1 与 128.0.0.0/1 把「到 VPN 服务器公网 IP」也送进 TUN，导致 TLS 断连（read: no route to host）。
		if ta, ok := raw.RemoteAddr().(*net.TCPAddr); ok {
			if ip := ta.IP.To4(); ip != nil {
				cu, errBypass := tuntap.AddBypassRouteForVPNServer(ip)
				if errBypass != nil {
					log.Warn("vpn server bypass route", "server_ip", ip.String(), "err", errBypass)
				} else {
					bypassCleanup = cu
				}
			}
		}
		var errSplit error
		splitCleanup, errSplit = splitDefault(tunName)
		if errSplit != nil {
			return errSplit
		}
	}

	log.Info("tunnel running (no further logs until error or Ctrl+C)", "tun", tunName, "client_ip", clientIP)

	go func() {
		<-ctx.Done()
		_ = raw.Close()
		if tunRelease != nil {
			tunRelease()
		}
	}()

	var wmu sync.Mutex
	write := func(t protocol.MsgType, p []byte) error {
		wmu.Lock()
		defer wmu.Unlock()
		return protocol.WriteFrame(conn, t, p)
	}

	errCh := make(chan error, 2)
	go func() {
		buf := make([]byte, 65535)
		for {
			select {
			case <-ctx.Done():
				errCh <- ctx.Err()
				return
			default:
			}
			n, err := tunReadWriter.Read(buf)
			if err != nil {
				errCh <- err
				return
			}
			if n <= 0 {
				continue
			}
			pkt := make([]byte, n)
			copy(pkt, buf[:n])
			if err := write(protocol.MsgData, pkt); err != nil {
				errCh <- err
				return
			}
		}
	}()
	go func() {
		for {
			select {
			case <-ctx.Done():
				errCh <- ctx.Err()
				return
			default:
			}
			fr, err := readFrameSafe(conn)
			if err != nil {
				if errors.Is(err, io.EOF) {
					errCh <- nil
					return
				}
				errCh <- err
				return
			}
			switch fr.Type {
			case protocol.MsgData:
				if _, err := tunReadWriter.Write(fr.Payload); err != nil {
					errCh <- err
					return
				}
			case protocol.MsgKeepalive:
				_ = write(protocol.MsgKeepalive, nil)
			default:
			}
		}
	}()
	err = <-errCh
	// 唤醒另一路阻塞读（TUN 或 TLS），避免死等第二路
	_ = raw.Close()
	if tunRelease != nil {
		tunRelease()
	}
	<-errCh
	return err
}

func writeFrameSafe(conn net.Conn, t protocol.MsgType, p []byte) error {
	return protocol.WriteFrame(conn, t, p)
}

func readFrameSafe(conn net.Conn) (*protocol.Frame, error) {
	return protocol.ReadFrame(conn)
}
