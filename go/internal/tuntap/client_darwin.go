//go:build darwin

package tuntap

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
)

func ConfigureClientPointToPoint(ifName, clientIP, serverIP string) error {
	cmd := exec.Command("ifconfig", ifName, clientIP, serverIP, "up")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ifconfig: %w: %s", err, out)
	}
	cmd = exec.Command("ifconfig", ifName, "mtu", fmt.Sprint(ClientIPv4MTU))
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ifconfig mtu: %w: %s", err, out)
	}
	return nil
}

func AddSplitDefaultRoutes(ifName string) error {
	// 使用 -netmask 形式：与 `0.0.0.0/1`、`128.0.0.0/1` 等价；部分 macOS 上 CIDR 写法偶发解析/拒绝。
	split := []struct{ net, mask string }{
		{"0.0.0.0", "128.0.0.0"},
		{"128.0.0.0", "128.0.0.0"},
	}
	for _, r := range split {
		cmd := exec.Command("route", "-n", "add", "-net", r.net, "-netmask", r.mask, "-interface", ifName)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("route add -net %s -netmask %s -interface %s: %w: %s", r.net, r.mask, ifName, err, out)
		}
	}
	return nil
}

// RemoveSplitDefaultRoutes removes split-default routes added by AddSplitDefaultRoutes (best effort).
func RemoveSplitDefaultRoutes(ifName string) {
	split := []struct{ net, mask string }{
		{"0.0.0.0", "128.0.0.0"},
		{"128.0.0.0", "128.0.0.0"},
	}
	for _, r := range split {
		_ = exec.Command("route", "delete", "-net", r.net, "-netmask", r.mask, "-interface", ifName).Run()
	}
}

// AddBypassRouteForVPNServer adds a host route so TLS to the VPN server stays on the physical default path.
// Must be called before AddSplitDefaultRoutes. Returned cleanup removes the host route (best effort).
func AddBypassRouteForVPNServer(ip net.IP) (cleanup func(), err error) {
	ip4 := ip.To4()
	if ip4 == nil {
		return func() {}, nil
	}
	s := net.IP(ip4).String()
	out, err := exec.Command("route", "-n", "get", s).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("route get %s: %w: %s", s, err, out)
	}
	var gw string
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "gateway:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				gw = fields[1]
			}
			break
		}
	}
	if gw == "" || gw == "127.0.0.1" || gw == s {
		return nil, fmt.Errorf("no usable gateway for %s in route output", s)
	}
	add := exec.Command("route", "-n", "add", "-host", s, gw)
	if out2, err2 := add.CombinedOutput(); err2 != nil {
		msg := string(out2)
		if !strings.Contains(msg, "File exists") {
			return nil, fmt.Errorf("route add -host %s %s: %w: %s", s, gw, err2, out2)
		}
	}
	return func() {
		_ = exec.Command("route", "delete", "-host", s, gw).Run()
	}, nil
}
