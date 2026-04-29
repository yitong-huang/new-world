//go:build !windows

package main

import (
	"io"

	"new.world/nw/internal/tuntap"
)

func openTun(ifname string) (rw io.ReadWriter, name string, cleanup func(), err error) {
	iface, err := tuntap.Open(ifname)
	if err != nil {
		return nil, "", nil, err
	}
	return iface, iface.Name(), func() { _ = iface.Close() }, nil
}
