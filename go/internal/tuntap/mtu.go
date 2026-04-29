package tuntap

// ClientIPv4MTU is the MTU set on the client TUN after bring-up.
// TLS + 帧头会吃掉一部分路径 MTU；若留 1500 易出现「部分 HTTPS 站点打不开」的黑洞现象。
const ClientIPv4MTU = 1360
