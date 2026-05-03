//go:build !darwin

package tuntap

import "log/slog"

func tunnelDNSUndoAfterChinaSplit(_ *slog.Logger, _ string) func() { return nil }
