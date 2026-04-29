//go:build linux || darwin

package tuntap

import (
	"fmt"
	"log/slog"
	"net"
	"sync"
	"sync/atomic"
)

const chinaRouteWorkers = 28

// SetupSplitDefaultWithChina adds split-default routes (0.0.0.0/1 + 128.0.0.0/1 via TUN), then
// installs more-specific IPv4 routes from routesFile (+ optional extraRoutesFile) via the current
// physical default gateway. Matching traffic bypasses the tunnel.
func SetupSplitDefaultWithChina(log *slog.Logger, ifName, routesFile, extraRoutesFile string) (cleanup func(), err error) {
	if routesFile == "" {
		return nil, fmt.Errorf("china routes file path is empty")
	}
	nets, err := LoadIPv4CIDRsFromFiles(routesFile, extraRoutesFile)
	if err != nil {
		return nil, err
	}
	gw, dev, err := defaultIPv4Gateway()
	if err != nil {
		return nil, fmt.Errorf("default gateway: %w", err)
	}
	if err := AddSplitDefaultRoutes(ifName); err != nil {
		return nil, err
	}

	if len(nets) == 0 {
		if log != nil {
			log.Warn("direct-routes files have no CIDR lines; only split-default is active", "china_file", routesFile, "extra_file", extraRoutesFile)
		}
		return func() { RemoveSplitDefaultRoutes(ifName) }, nil
	}

	var added []*net.IPNet
	var addedMu sync.Mutex
	var fail atomic.Uint32

	jobCh := make(chan *net.IPNet, chinaRouteWorkers*2)
	var wg sync.WaitGroup
	for w := 0; w < chinaRouteWorkers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := range jobCh {
				if e := addChinaRoute(n, gw, dev); e != nil {
					if log != nil {
						log.Warn("china route add", "cidr", n.String(), "err", e)
					}
					fail.Add(1)
					continue
				}
				addedMu.Lock()
				added = append(added, n)
				addedMu.Unlock()
			}
		}()
	}
	for _, n := range nets {
		jobCh <- n
	}
	close(jobCh)
	wg.Wait()

	if int(fail.Load()) > 0 && len(added) == 0 {
		RemoveSplitDefaultRoutes(ifName)
		return nil, fmt.Errorf("all %d china route additions failed", fail.Load())
	}

	cleanup = func() {
		for _, n := range added {
			delChinaRoute(n, gw, dev)
		}
		RemoveSplitDefaultRoutes(ifName)
	}
	if log != nil {
		log.Info("split routing: direct routes installed", "ok", len(added), "failed", fail.Load(), "gw", gw, "dev", dev, "tun", ifName, "china_file", routesFile, "extra_file", extraRoutesFile)
	}
	return cleanup, nil
}
