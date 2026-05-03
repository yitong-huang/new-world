//go:build darwin

package tuntap

import (
	"log/slog"
	"strings"
)

// ipv6MitigationUndoAfterSplitDefault 在 AddSplitDefaultRoutes 成功后调用；physicalDev 须为添加路由前的 defaultIPv4Gateway() 设备名。
func ipv6MitigationUndoAfterSplitDefault(log *slog.Logger, physicalDev string) func() {
	if mitigationSkippedByEnvOrFlag() {
		return nil
	}
	if strings.HasPrefix(physicalDev, "utun") {
		return nil
	}
	svc, err := networkServiceNameForDevice(physicalDev)
	if err != nil {
		if log != nil {
			log.Warn("darwin ipv6 mitigation: no network service for device", "dev", physicalDev, "err", err)
		}
		return nil
	}
	undo, err := applyDarwinIPv6MitigationWithFallback(svc, log)
	if err != nil {
		if log != nil {
			log.Warn("darwin ipv6 mitigation: setv6off failed (primary + all-services fallback)", "service", svc, "err", err)
		}
		return nil
	}
	return undo
}
