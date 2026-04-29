//go:build windows

package wtun

import (
	"io"
	"runtime"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wintun"
)

// Device exposes Wintun as a simple byte stream for IPv4 packets (layer 3).
type Device struct {
	ad *wintun.Adapter
	s  wintun.Session
}

func Open() (*Device, func(), error) {
	wintun.MustMinimumVersion()
	ad, err := wintun.CreateAdapter("NWVPN", "Tunnel", nil)
	if err != nil {
		return nil, nil, err
	}
	s, err := ad.StartSession(0x200000)
	if err != nil {
		_ = ad.Close()
		return nil, nil, err
	}
	d := &Device{ad: ad, s: s}
	cleanup := func() {
		s.End()
		_ = ad.Close()
	}
	return d, cleanup, nil
}

func (d *Device) Read(p []byte) (int, error) {
	for {
		pkt, err := d.s.ReceivePacket()
		if err != nil {
			if err == windows.ERROR_NO_MORE_ITEMS {
				_, _ = windows.WaitForSingleObject(d.s.ReadWaitEvent(), windows.INFINITE)
				runtime.Gosched()
				continue
			}
			return 0, err
		}
		if len(pkt) > len(p) {
			d.s.ReleaseReceivePacket(pkt)
			return 0, io.ErrShortBuffer
		}
		n := copy(p, pkt)
		d.s.ReleaseReceivePacket(pkt)
		return n, nil
	}
}

func (d *Device) Write(p []byte) (int, error) {
	buf, err := d.s.AllocateSendPacket(len(p))
	if err != nil {
		return 0, err
	}
	copy(buf, p)
	d.s.SendPacket(buf)
	return len(p), nil
}

func (d *Device) Name() string {
	if d.ad == nil {
		return "NWVPN"
	}
	n, err := d.ad.Name()
	if err != nil || n == "" {
		return "NWVPN"
	}
	return n
}
