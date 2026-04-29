//go:build linux

package tuntap

import (
	"fmt"
	"os/exec"
	"strings"
)

// defaultIPv4Gateway returns the first IPv4 default route's next hop and device.
func defaultIPv4Gateway() (gw string, dev string, err error) {
	out, err := exec.Command("ip", "-4", "route", "show", "default").CombinedOutput()
	if err != nil {
		return "", "", fmt.Errorf("ip route show default: %w: %s", err, out)
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || !strings.HasPrefix(line, "default") {
			continue
		}
		fields := strings.Fields(line)
		for i := 0; i < len(fields)-1; i++ {
			switch fields[i] {
			case "via":
				gw = fields[i+1]
			case "dev":
				dev = fields[i+1]
			}
		}
		if gw != "" && dev != "" {
			return gw, dev, nil
		}
	}
	return "", "", fmt.Errorf("no default ipv4 route in: %q", strings.TrimSpace(string(out)))
}
