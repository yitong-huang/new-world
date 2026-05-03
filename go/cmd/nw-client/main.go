package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"flag"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"runtime"
	"sync"

	"new.world/nw/internal/authcfg"
	"new.world/nw/internal/client"
	"new.world/nw/internal/tuntap"
)

func main() {
	server := flag.String("server", "new-world-kr-01.2fish.com.cn:8443", "host:port of nw-server")
	ca := flag.String("cacert", "certs/server.crt", "PEM CA to verify server (or server cert for dev)")
	insecure := flag.Bool("insecure", false, "skip TLS verification (dev only)")
	ifname := flag.String("ifname", "", "TUN name hint (unix); ignored on Windows Wintun")
	split := flag.Bool("split-default", false, "add 0.0.0.0/1 and 128.0.0.0/1 via tunnel (Linux/Darwin)")
	chinaRoutes := flag.String("china-routes", "", "IPv4 CIDR list file: with -split-default, add those nets via physical gateway (domestic direct); Linux/macOS only")
	extraDirectRoutes := flag.String("extra-direct-routes", "", "optional extra IPv4 CIDR list file merged with -china-routes (for patch overrides)")
	authFile := flag.String("auth-file", "", "JSON with username/password (configs/auth.client.example.json); if set, sent after ClientHello")
	noIPv6Mitigation := flag.Bool("no-ipv6-mitigation", false, "Darwin only: do not disable IPv6 on the primary interface when using -split-default (IPv6 may bypass the IPv4 tunnel)")
	flag.Parse()

	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	tuntap.SetDarwinIPv6Mitigation(!*noIPv6Mitigation)

	if *chinaRoutes != "" && !*split {
		log.Error("-china-routes requires -split-default")
		os.Exit(1)
	}
	if *extraDirectRoutes != "" && !*split {
		log.Error("-extra-direct-routes requires -split-default")
		os.Exit(1)
	}
	if *extraDirectRoutes != "" && *chinaRoutes == "" {
		log.Error("-extra-direct-routes requires -china-routes")
		os.Exit(1)
	}
	if *chinaRoutes != "" {
		if _, err := os.Stat(*chinaRoutes); err != nil {
			log.Error("china-routes file", "path", *chinaRoutes, "err", err)
			os.Exit(1)
		}
	}
	if *extraDirectRoutes != "" {
		if _, err := os.Stat(*extraDirectRoutes); err != nil {
			log.Error("extra-direct-routes file", "path", *extraDirectRoutes, "err", err)
			os.Exit(1)
		}
	}

	tlsCfg := &tls.Config{MinVersion: tls.VersionTLS13}
	if *insecure {
		tlsCfg.InsecureSkipVerify = true
	} else {
		b, err := os.ReadFile(*ca)
		if err != nil {
			log.Error("read cacert", "err", err)
			os.Exit(1)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(b) {
			log.Error("parse cacert pem")
			os.Exit(1)
		}
		tlsCfg.RootCAs = pool
	}

	// tls.Client 不会自动填 ServerName；校验证书时必须与 SAN/CN 一致（Go 要求显式设置其一）。
	if !tlsCfg.InsecureSkipVerify {
		host, _, err := net.SplitHostPort(*server)
		if err != nil {
			host = *server
		}
		if host != "" {
			tlsCfg.ServerName = host
		}
	}

	rw, tunName, cleanup, err := openTun(*ifname)
	if err != nil {
		log.Error("open tun", "err", err)
		os.Exit(1)
	}
	var cleanOnce sync.Once
	releaseTun := func() { cleanOnce.Do(func() { cleanup() }) }
	defer releaseTun()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	go func() {
		<-ctx.Done()
		releaseTun()
	}()

	setup := func(ifn, clientIP, serverIP string) error {
		return tuntap.ConfigureClientPointToPoint(ifn, clientIP, serverIP)
	}
	var splitFn func(string) (func(), error)
	if *split {
		if *chinaRoutes != "" {
			splitFn = func(ifName string) (func(), error) {
				return tuntap.SetupSplitDefaultWithChina(log, ifName, *chinaRoutes, *extraDirectRoutes)
			}
		} else {
			splitFn = func(ifName string) (func(), error) {
				if runtime.GOOS == "darwin" {
					return tuntap.AddSplitDefaultRoutesDarwinWithIPv6Mitigation(ifName, log)
				}
				if err := tuntap.AddSplitDefaultRoutes(ifName); err != nil {
					return nil, err
				}
				return func() { tuntap.RemoveSplitDefaultRoutes(ifName) }, nil
			}
		}
	}

	authUser, authPass := "", ""
	if *authFile != "" {
		u, p, err := authcfg.LoadClient(*authFile)
		if err != nil {
			log.Error("load auth-file", "path", *authFile, "err", err)
			os.Exit(1)
		}
		authUser, authPass = u, p
	}

	if err := client.Run(ctx, log, tlsCfg, *server, tunName, rw, authUser, authPass, setup, splitFn, releaseTun); err != nil {
		log.Error("client", "err", err)
		os.Exit(1)
	}
}
