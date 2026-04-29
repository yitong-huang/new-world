//go:build linux

package tuntap

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
)

// ConfigureClientPointToPoint sets IPv4 on TUN with peer (server side of PtP).
func ConfigureClientPointToPoint(ifName, clientIP, serverIP string) error {
	cmd := exec.Command("ip", "addr", "flush", "dev", ifName)
	_ = cmd.Run()
	cmd = exec.Command("ip", "addr", "add", clientIP+"/32", "peer", serverIP, "dev", ifName)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ip addr add peer: %w: %s", err, out)
	}
	cmd = exec.Command("ip", "link", "set", "dev", ifName, "up")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ip link: %w: %s", err, out)
	}
	cmd = exec.Command("ip", "link", "set", "dev", ifName, "mtu", fmt.Sprint(ClientIPv4MTU))
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ip link mtu: %w: %s", err, out)
	}
	return nil
}

// AddSplitDefaultRoutes adds 0.0.0.0/1 and 128.0.0.0/1 via ifName (does not remove original default).
func AddSplitDefaultRoutes(ifName string) error {
	for _, cidr := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
		cmd := exec.Command("ip", "route", "replace", cidr, "dev", ifName)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("ip route %s: %w: %s", cidr, err, out)
		}
	}
	return nil
}

// AddBypassRouteForVPNServer adds /32 via default gateway dev so TLS to the server is not pulled into TUN.
// Must be called before AddSplitDefaultRoutes.
func AddBypassRouteForVPNServer(ip net.IP) (cleanup func(), err error) {
	ip4 := ip.To4()
	if ip4 == nil {
		return func() {}, nil
	}
	s := net.IP(ip4).String()
	out, err := exec.Command("ip", "route", "get", s).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("ip route get %s: %w: %s", s, err, out)
	}
	line := strings.TrimSpace(string(out))
	var gw, dev string
	fields := strings.Fields(line)
	for i := 0; i < len(fields)-1; i++ {
		switch fields[i] {
		case "via":
			gw = fields[i+1]
		case "dev":
			dev = fields[i+1]
		}
	}
	if gw == "" || dev == "" {
		return nil, fmt.Errorf("parse ip route get %q", line)
	}
	cmd := exec.Command("ip", "route", "replace", s+"/32", "via", gw, "dev", dev)
	if out2, err2 := cmd.CombinedOutput(); err2 != nil {
		return nil, fmt.Errorf("ip route replace %s/32: %w: %s", s, err2, out2)
	}
	return func() {
		_ = exec.Command("ip", "route", "del", s+"/32", "via", gw, "dev", dev).Run()
		_ = exec.Command("ip", "route", "del", s+"/32").Run()
	}, nil
}
