//go:build windows

package main

import (
	"io"

	"new.world/nw/internal/wtun"
)

func openTun(_ string) (rw io.ReadWriter, name string, cleanup func(), err error) {
	dev, cleanup, err := wtun.Open()
	if err != nil {
		return nil, "", nil, err
	}
	return dev, dev.Name(), cleanup, nil
}
