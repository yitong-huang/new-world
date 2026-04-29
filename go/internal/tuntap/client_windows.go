//go:build windows

package tuntap

import "net"

// AddBypassRouteForVPNServer is a no-op on Windows; configure split routing / exclusions manually if needed.
func AddBypassRouteForVPNServer(net.IP) (func(), error) {
	return func() {}, nil
}

// ConfigureClientPointToPoint is a no-op here: assign the Wintun adapter IPv4 in Windows
// (netsh / PowerShell / COM) per docs/signing-and-ops.md before relying on split routes.
func ConfigureClientPointToPoint(_ ifName, _ clientIP, _ serverIP string) error {
	return nil
}

// AddSplitDefaultRoutes is not automated on Windows in this repo; add routes manually if needed.
func AddSplitDefaultRoutes(_ ifName string) error {
	return nil
}
