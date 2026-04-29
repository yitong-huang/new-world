package netx

import "net"

// tunnelReadWriteBuf is SO_RCVBUF/SO_SNDBUF for the single TLS carrier socket (OS may clamp).
const tunnelReadWriteBuf = 4 << 20

// TuneTunnelTransport applies TCP_NODELAY and large buffers on the TCP connection carrying TLS.
// Accepts *net.TCPConn or *tls.Conn (anything implementing NetConn() -> *net.TCPConn).
func TuneTunnelTransport(c net.Conn) {
	tcp := underlyingTCP(c)
	if tcp == nil {
		return
	}
	_ = tcp.SetNoDelay(true)
	_ = tcp.SetReadBuffer(tunnelReadWriteBuf)
	_ = tcp.SetWriteBuffer(tunnelReadWriteBuf)
}

func underlyingTCP(c net.Conn) *net.TCPConn {
	if t, ok := c.(*net.TCPConn); ok {
		return t
	}
	type withNetConn interface {
		NetConn() net.Conn
	}
	w, ok := c.(withNetConn)
	if !ok {
		return nil
	}
	t, ok := w.NetConn().(*net.TCPConn)
	if !ok {
		return nil
	}
	return t
}
