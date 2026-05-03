//go:build darwin

package tuntap

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"
)

var darwinIPv6MitigationEnabled = true

// SetDarwinIPv6Mitigation 由 nw-client 根据 -no-ipv6-mitigation 设置。
func SetDarwinIPv6Mitigation(enabled bool) { darwinIPv6MitigationEnabled = enabled }

func networkServiceNameForDevice(device string) (string, error) {
	out, err := exec.Command("networksetup", "-listallhardwareports").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("listallhardwareports: %w: %s", err, out)
	}
	var currentPort string
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Hardware Port:") {
			currentPort = strings.TrimSpace(strings.TrimPrefix(line, "Hardware Port:"))
			continue
		}
		if strings.HasPrefix(line, "Device:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 && fields[1] == device && currentPort != "" {
				return currentPort, nil
			}
		}
	}
	return "", fmt.Errorf("no Hardware Port mapping for device %q", device)
}

func mitigationSkippedByEnvOrFlag() bool {
	if os.Getenv("NW_IPV6_MITIGATION") == "0" {
		return true
	}
	return !darwinIPv6MitigationEnabled
}

// ResolveIPv4DefaultNetworkService 在尚未添加 split-default 路由之前调用，解析当前 IPv4 默认出口对应的 networksetup 服务名。
func ResolveIPv4DefaultNetworkService() (service string, skip bool, err error) {
	if mitigationSkippedByEnvOrFlag() {
		return "", true, nil
	}
	_, dev, err := defaultIPv4Gateway()
	if err != nil {
		return "", false, err
	}
	if strings.HasPrefix(dev, "utun") {
		return "", true, nil
	}
	svc, err := networkServiceNameForDevice(dev)
	if err != nil {
		return "", false, err
	}
	return svc, false, nil
}

// ApplySetV6Off runs networksetup -setv6off; undo restores -setv6automatic.
func ApplySetV6Off(service string, log *slog.Logger) (undo func(), err error) {
	if service == "" {
		return func() {}, nil
	}
	out, err := exec.Command("networksetup", "-setv6off", service).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("networksetup -setv6off %q: %w: %s", service, err, out)
	}
	if log != nil {
		log.Info("darwin: IPv6 disabled on network service (IPv4-only tunnel)", "service", service)
	}
	return func() {
		_, _ = exec.Command("networksetup", "-setv6automatic", service).CombinedOutput()
		if log != nil {
			log.Info("darwin: IPv6 restored on network service", "service", service)
		}
	}, nil
}

func listEnabledNetworkServiceNames() ([]string, error) {
	out, err := exec.Command("networksetup", "-listallnetworkservices").CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("listallnetworkservices: %w: %s", err, out)
	}
	var names []string
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		lower := strings.ToLower(line)
		if strings.Contains(lower, "asterisk") && strings.Contains(lower, "denotes") {
			continue
		}
		if strings.HasPrefix(line, "*") {
			continue
		}
		names = append(names, line)
	}
	return names, nil
}

// ApplySetV6OffAllNetworkServices 对每个已启用的网络服务执行 setv6off（至少成功一个则返回组合 undo）。
func ApplySetV6OffAllNetworkServices(log *slog.Logger) (undo func(), err error) {
	names, err := listEnabledNetworkServiceNames()
	if err != nil {
		return nil, err
	}
	var undos []func()
	var firstErr error
	ok := 0
	for _, name := range names {
		u, e := ApplySetV6Off(name, log)
		if e != nil {
			if firstErr == nil {
				firstErr = e
			}
			continue
		}
		undos = append(undos, u)
		ok++
	}
	if ok == 0 {
		return nil, fmt.Errorf("setv6off: no network service succeeded (tried %d): %w", len(names), firstErr)
	}
	return func() {
		for i := len(undos) - 1; i >= 0; i-- {
			undos[i]()
		}
	}, nil
}

// applyDarwinIPv6MitigationWithFallback 先关闭 primary 对应服务 IPv6；失败则对所有已启用服务尝试（修复单一服务 setv6off 失败时仍残留 IPv6 默认路由、AAAA 绕开 utun）。
func applyDarwinIPv6MitigationWithFallback(primary string, log *slog.Logger) (undo func(), err error) {
	if mitigationSkippedByEnvOrFlag() {
		return func() {}, nil
	}
	if primary != "" {
		u, err := ApplySetV6Off(primary, log)
		if err == nil {
			return u, nil
		}
		if log != nil {
			log.Warn("darwin: IPv6 mitigation on primary service failed, falling back to all network services", "service", primary, "err", err)
		}
	}
	return ApplySetV6OffAllNetworkServices(log)
}

// AddSplitDefaultRoutesDarwinWithIPv6Mitigation 等价于 AddSplitDefaultRoutes + 关闭默认物理口 IPv6（避免走 AAAA 绕开隧道）。
func AddSplitDefaultRoutesDarwinWithIPv6Mitigation(ifName string, log *slog.Logger) (cleanup func(), err error) {
	svc, skip, err := ResolveIPv4DefaultNetworkService()
	if err != nil {
		return nil, err
	}
	if err := AddSplitDefaultRoutes(ifName); err != nil {
		return nil, err
	}
	if skip || svc == "" {
		return func() { RemoveSplitDefaultRoutes(ifName) }, nil
	}
	undoV6, err := applyDarwinIPv6MitigationWithFallback(svc, log)
	if err != nil {
		RemoveSplitDefaultRoutes(ifName)
		return nil, err
	}
	var undoDNS func()
	if u, errDNS := ApplyTunnelFriendlyDNS(svc, log); errDNS != nil {
		if log != nil {
			log.Warn("darwin: tunnel-friendly DNS not applied", "service", svc, "err", errDNS)
		}
	} else {
		undoDNS = u
	}
	return func() {
		RemoveSplitDefaultRoutes(ifName)
		if undoDNS != nil {
			undoDNS()
		}
		undoV6()
	}, nil
}
