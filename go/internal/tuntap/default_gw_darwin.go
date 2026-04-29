//go:build darwin

package tuntap

import (
	"fmt"
	"os/exec"
	"strings"
)

// defaultIPv4Gateway returns the current IPv4 default gateway and outbound interface
// (queried before split-default routes are applied).
func defaultIPv4Gateway() (gw string, dev string, err error) {
	out, err := exec.Command("route", "-n", "get", "default").CombinedOutput()
	if err != nil {
		return "", "", fmt.Errorf("route get default: %w: %s", err, out)
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "gateway:") {
			f := strings.Fields(line)
			if len(f) >= 2 {
				gw = f[1]
			}
			continue
		}
		if strings.HasPrefix(line, "interface:") {
			f := strings.Fields(line)
			if len(f) >= 2 {
				dev = f[1]
			}
		}
	}
	if gw == "" || dev == "" {
		return "", "", fmt.Errorf("parse default route from route get: %q", string(out))
	}
	return gw, dev, nil
}
