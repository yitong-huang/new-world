//go:build darwin

package tuntap

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"time"
)

// networksetup 在部分系统/网络状态下可能长时间阻塞；超时则放弃改 DNS，避免 nw-client 卡死。
const networkSetupCmdTimeout = 12 * time.Second

func networksetupCombinedOutput(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), networkSetupCmdTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "networksetup", args...)
	return cmd.CombinedOutput()
}

func tunnelDNSSkippedByEnv() bool {
	return os.Getenv("NW_TUNNEL_DNS") == "0"
}

func parseDNSServersOutput(out string) (servers []string, wasDHCPAutomatic bool) {
	s := strings.TrimSpace(out)
	if s == "" {
		return nil, true
	}
	lower := strings.ToLower(s)
	if strings.Contains(lower, "there aren't any dns servers") {
		return nil, true
	}
	// 部分简体中文系统为「没有设定任何 … DNS 服务器」等，保守匹配关键词。
	if strings.Contains(s, "DNS") && (strings.Contains(s, "没有") || strings.Contains(s, "無")) {
		return nil, true
	}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.Contains(line, ".") || strings.Contains(line, ":") {
			servers = append(servers, line)
		}
	}
	if len(servers) == 0 {
		return nil, true
	}
	return servers, false
}

func getNetworkServiceDNSServers(service string) (servers []string, wasDHCPAutomatic bool, err error) {
	out, err := networksetupCombinedOutput("-getdnsservers", service)
	if err != nil {
		return nil, false, fmt.Errorf("networksetup -getdnsservers %q: %w: %s", service, err, out)
	}
	srv, dhcp := parseDNSServersOutput(string(out))
	return srv, dhcp, nil
}

func applyNetworkServiceDNSServers(service string, servers []string, wasDHCPAutomatic bool) error {
	var args []string
	if wasDHCPAutomatic || len(servers) == 0 {
		args = []string{"-setdnsservers", service, "Empty"}
	} else {
		args = append([]string{"-setdnsservers", service}, servers...)
	}
	out, err := networksetupCombinedOutput(args...)
	if err != nil {
		return fmt.Errorf("networksetup setdnsservers %q: %w: %s", service, err, out)
	}
	return nil
}

// ApplyTunnelFriendlyDNS 将指定网络服务 DNS 设为公网解析器，使查询走 split-default → utun（避免国内解析污染）。
// 退出时恢复原先 getdnsservers 状态；可通过 NW_TUNNEL_DNS=0 禁用。
func ApplyTunnelFriendlyDNS(service string, log *slog.Logger) (undo func(), err error) {
	if tunnelDNSSkippedByEnv() || service == "" {
		return func() {}, nil
	}
	prev, wasDHCP, err := getNetworkServiceDNSServers(service)
	if err != nil {
		return nil, err
	}
	out, err := networksetupCombinedOutput("-setdnsservers", service, "8.8.8.8", "1.1.1.1")
	if err != nil {
		return nil, fmt.Errorf("networksetup -setdnsservers %q 8.8.8.8 1.1.1.1: %w: %s", service, err, out)
	}
	if log != nil {
		log.Info("darwin: tunnel-friendly DNS (queries via split-default)", "service", service)
	}
	return func() {
		if e := applyNetworkServiceDNSServers(service, prev, wasDHCP); e != nil {
			if log != nil {
				log.Warn("darwin: restore DNS failed", "service", service, "err", e)
			}
			return
		}
		if log != nil {
			log.Info("darwin: restored DNS", "service", service)
		}
	}, nil
}

func tunnelDNSUndoAfterChinaSplit(log *slog.Logger, physicalDev string) func() {
	if physicalDev == "" || strings.HasPrefix(physicalDev, "utun") {
		return nil
	}
	svc, err := networkServiceNameForDevice(physicalDev)
	if err != nil {
		if log != nil {
			log.Warn("darwin tunnel DNS: no network service for device", "dev", physicalDev, "err", err)
		}
		return nil
	}
	u, err := ApplyTunnelFriendlyDNS(svc, log)
	if err != nil {
		if log != nil {
			log.Warn("darwin tunnel DNS not applied", "service", svc, "err", err)
		}
		return nil
	}
	return u
}
