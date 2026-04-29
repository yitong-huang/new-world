package tuntap

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strings"
)

// LoadIPv4CIDRsFromFile reads one IPv4 CIDR per line (# starts comment, blank lines skipped).
func LoadIPv4CIDRsFromFile(path string) ([]*net.IPNet, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var out []*net.IPNet
	s := bufio.NewScanner(f)
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = strings.TrimSpace(line[:i])
		}
		if line == "" {
			continue
		}
		ip, n, err := net.ParseCIDR(line)
		if err != nil {
			return nil, fmt.Errorf("parse CIDR %q: %w", line, err)
		}
		if ip4 := ip.To4(); ip4 == nil {
			return nil, fmt.Errorf("only IPv4 CIDR supported, got %q", line)
		}
		out = append(out, n)
	}
	if err := s.Err(); err != nil {
		return nil, err
	}
	return out, nil
}

// LoadIPv4CIDRsFromFiles loads and merges multiple IPv4 CIDR files.
// Empty path entries are ignored; duplicate CIDRs are removed by canonical CIDR string.
func LoadIPv4CIDRsFromFiles(paths ...string) ([]*net.IPNet, error) {
	var out []*net.IPNet
	seen := make(map[string]struct{})
	for _, p := range paths {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		nets, err := LoadIPv4CIDRsFromFile(p)
		if err != nil {
			return nil, fmt.Errorf("load %s: %w", p, err)
		}
		for _, n := range nets {
			key := n.String()
			if _, ok := seen[key]; ok {
				continue
			}
			seen[key] = struct{}{}
			out = append(out, n)
		}
	}
	return out, nil
}
