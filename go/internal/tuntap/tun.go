package tuntap

import (
	"fmt"
	"os/exec"
	"runtime"

	"github.com/songgao/water"
)

// Open creates a TUN interface. If name is empty the OS picks a name.
func Open(name string) (*water.Interface, error) {
	cfg := water.Config{
		DeviceType: water.TUN,
	}
	if name != "" {
		cfg.Name = name
	}
	return water.New(cfg)
}

// ConfigureServerIPv4 assigns addrCIDR like "10.77.0.1/24" and brings interface up (best effort).
func ConfigureServerIPv4(ifName, addrCIDR string) error {
	switch runtime.GOOS {
	case "linux":
		cmd := exec.Command("ip", "addr", "replace", addrCIDR, "dev", ifName)
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("ip addr: %w: %s", err, out)
		}
		cmd = exec.Command("ip", "link", "set", "dev", ifName, "up")
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("ip link: %w: %s", err, out)
		}
		return nil
	case "darwin":
		// utun needs a point-to-point peer or ifconfig returns SIOCAIFADDR "Destination address required".
		ip, mask, err := parseCIDR4(addrCIDR)
		if err != nil {
			return err
		}
		peer, err := nextIPv4Addr(ip)
		if err != nil {
			return err
		}
		cmd := exec.Command("ifconfig", ifName, ip, peer, "netmask", mask, "up")
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("ifconfig: %w: %s", err, out)
		}
		return nil
	default:
		return fmt.Errorf("tuntap: unsupported GOOS %s", runtime.GOOS)
	}
}
