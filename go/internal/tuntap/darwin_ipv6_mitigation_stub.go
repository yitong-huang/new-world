//go:build !darwin

package tuntap

import "log/slog"

func SetDarwinIPv6Mitigation(_ bool) {}

// AddSplitDefaultRoutesDarwinWithIPv6Mitigation 非 Darwin 上等同于仅 IPv4 split。
func AddSplitDefaultRoutesDarwinWithIPv6Mitigation(ifName string, _ *slog.Logger) (cleanup func(), err error) {
	if err := AddSplitDefaultRoutes(ifName); err != nil {
		return nil, err
	}
	return func() { RemoveSplitDefaultRoutes(ifName) }, nil
}
