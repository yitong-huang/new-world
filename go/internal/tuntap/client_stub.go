//go:build !linux && !darwin && !windows

package tuntap

import (
	"fmt"
	"net"
)

// AddBypassRouteForVPNServer is not implemented on this GOOS.
func AddBypassRouteForVPNServer(net.IP) (func(), error) {
	return func() {}, nil
}

func ConfigureClientPointToPoint(ifName, clientIP, serverIP string) error {
	return fmt.Errorf("ConfigureClientPointToPoint: not implemented on this GOOS")
}

func AddSplitDefaultRoutes(ifName string) error {
	return fmt.Errorf("AddSplitDefaultRoutes: not implemented on this GOOS")
}

func RemoveSplitDefaultRoutes(ifName string) {}
