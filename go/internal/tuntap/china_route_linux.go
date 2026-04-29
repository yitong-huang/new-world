//go:build linux

package tuntap

import (
	"fmt"
	"net"
	"os/exec"
)

func addChinaRoute(n *net.IPNet, gw, dev string) error {
	cidr := n.String()
	out, err := exec.Command("ip", "route", "replace", cidr, "via", gw, "dev", dev).CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip route replace %s: %w: %s", cidr, err, out)
	}
	return nil
}

func delChinaRoute(n *net.IPNet, gw, dev string) {
	cidr := n.String()
	_ = exec.Command("ip", "route", "del", cidr, "via", gw, "dev", dev).Run()
}
