//go:build !linux && !darwin

package tuntap

import (
	"fmt"
	"log/slog"
)

// SetupSplitDefaultWithChina is only implemented on Linux and macOS.
func SetupSplitDefaultWithChina(_ *slog.Logger, _ string, _ string, _ string) (func(), error) {
	return nil, fmt.Errorf("SetupSplitDefaultWithChina: only Linux and macOS are supported")
}
