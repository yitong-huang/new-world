//go:build linux

package tuntap

import "log/slog"

func ipv6MitigationUndoAfterSplitDefault(_ *slog.Logger, _ string) func() { return nil }
