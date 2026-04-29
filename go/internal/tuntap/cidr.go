package tuntap

import (
	"fmt"
	"net"
	"strconv"
	"strings"
)

// nextIPv4Addr returns another host on the same /24-style link (last octet ±1) for Darwin P2P ifconfig.
func nextIPv4Addr(ipStr string) (string, error) {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return "", fmt.Errorf("bad IPv4: %s", ipStr)
	}
	v4 := ip.To4()
	if v4 == nil {
		return "", fmt.Errorf("need IPv4: %s", ipStr)
	}
	peer := make(net.IP, len(v4))
	copy(peer, v4)
	if v4[3] < 255 {
		peer[3]++
	} else {
		peer[3]--
	}
	return peer.String(), nil
}

func parseCIDR4(cidr string) (ip string, netmask string, err error) {
	parts := strings.SplitN(cidr, "/", 2)
	if len(parts) != 2 {
		return "", "", fmt.Errorf("bad cidr")
	}
	ip = parts[0]
	bits, err := strconv.Atoi(parts[1])
	if err != nil || bits < 0 || bits > 32 {
		return "", "", fmt.Errorf("bad prefix")
	}
	m := uint32(0xffffffff)
	if bits < 32 {
		m = (m << uint(32-bits)) & 0xffffffff
	}
	a, b, c, d := byte(m>>24), byte(m>>16), byte(m>>8), byte(m)
	netmask = fmt.Sprintf("%d.%d.%d.%d", a, b, c, d)
	return ip, netmask, nil
}
