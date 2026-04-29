//go:build darwin

package tuntap

import (
	"fmt"
	"net"
	"os/exec"
	"strings"
)

func maskIPv4Dotted(m net.IPMask) string {
	ip4 := net.IP(m).To4()
	if ip4 == nil {
		return ""
	}
	return ip4.String()
}

func addChinaRoute(n *net.IPNet, gw, dev string) error {
	ones, bits := n.Mask.Size()
	if bits != 32 {
		return fmt.Errorf("non-ipv4 net %v", n)
	}
	var cmd *exec.Cmd
	if ones == 32 {
		cmd = exec.Command("route", "-n", "add", "-host", n.IP.String(), gw)
	} else {
		network := n.IP.Mask(n.Mask).String()
		mask := maskIPv4Dotted(n.Mask)
		if mask == "" {
			return fmt.Errorf("bad mask for %v", n)
		}
		cmd = exec.Command("route", "-n", "add", "-net", network, "-netmask", mask, gw)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		msg := string(out)
		if strings.Contains(msg, "File exists") {
			return nil
		}
		return fmt.Errorf("%s: %w: %s", cmd.Args, err, out)
	}
	_ = dev // Darwin gateway route does not need explicit dev here
	return nil
}

func delChinaRoute(n *net.IPNet, gw, dev string) {
	ones, bits := n.Mask.Size()
	if bits != 32 {
		return
	}
	if ones == 32 {
		_ = exec.Command("route", "delete", "-host", n.IP.String(), gw).Run()
		return
	}
	network := n.IP.Mask(n.Mask).String()
	mask := maskIPv4Dotted(n.Mask)
	if mask == "" {
		return
	}
	_ = exec.Command("route", "delete", "-net", network, "-netmask", mask, gw).Run()
	_ = dev
}
