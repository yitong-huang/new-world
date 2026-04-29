# NewWorld NW VPN

跨平台自定义 VPN（TLS 隧道 + TUN）：Go 服务端/桌面客户端、Swift（Network Extension）、Kotlin（`VpnService`）。协议与部署细节见 [`docs/protocol-v1.md`](docs/protocol-v1.md)、[`docs/server-deploy.md`](docs/server-deploy.md)、[`docs/signing-and-ops.md`](docs/signing-and-ops.md)。

---

## 1. 开发证书（一次性）

在仓库**根目录**执行（依赖本机 `openssl`）：

```bash
bash scripts/gen-certs.sh
```

产出写入 `certs/`（该目录下敏感文件已被 `.gitignore` 忽略）。服务端证书 SAN 默认包含 **`new-world-kr-01.2fish.com.cn`**（与默认客户端地址一致）；若用公网 IP 连接可追加：`NW_CERT_SAN_EXTRA=IP:x.x.x.x bash scripts/gen-certs.sh`。改 SAN 后需重新部署 `certs/` 到服务器，并在本机用新的 `server.crt` 作为 `-cacert`。生产环境请换用正式 CA，见 `docs/server-deploy.md`。

---

## 2. Go：`nw-server` / `nw-client`

**环境**：安装 [Go](https://go.golang.org/dl/) 1.22+，并将 `go` 加入 `PATH`。若拉模块超时，可临时使用：

```bash
export GOPROXY=https://goproxy.cn,direct
```

**编译**（在 `go/` 目录下）：

```bash
cd go
go mod download
go build -o nw-server ./cmd/nw-server
go build -o nw-client ./cmd/nw-client
```

**本机联调示例**（macOS/Linux，创建 TUN 需 root）：

```bash
cd go
sudo ./nw-server -listen 127.0.0.1:8443 \
  -cert ../certs/server.crt -key ../certs/server.key
```

另开终端（`nw-client` 默认连接 **`new-world-kr-01.2fish.com.cn:8443`**；本机连本地服务端时请显式传入 `-server 127.0.0.1:8443`）：

```bash
cd go
sudo ./nw-client -cacert ../certs/server.crt
```

### 远程一键部署（`scripts/deploy-nw-server.sh`）

在仓库根目录、已执行 `bash scripts/gen-certs.sh` 的前提下，通过 SSH 同步 **`go/`** 与**本机整个 `certs/` 目录**（`gen-certs.sh` 产出的 server/client 等文件一并上传）到远程 Linux；**检查 Go（>=1.22，否则从 go.dev 安装到 `/usr/local/go`）**，编译 `nw-server` 并以 `nohup` 监听 **`0.0.0.0:8443`**（可用 `NW_LISTEN` 覆盖）。远端 `nw-server` 仍只使用 `certs/server.crt` 与 `certs/server.key`。

```bash
# 方式 A：编辑 scripts/deploy-nw-server.sh 顶部「凭据区」，设置 DEPLOY_SSH_PASSWORD='你的密码'（勿提交到 git）
# 方式 B：export NW_SSH_PASSWORD='...'（同上，勿写入仓库）
bash scripts/deploy-nw-server.sh
```

首次部署若远程尚无 `/opt/nwvpn`，脚本会自动 **`mkdir -p`**；若仍出现 rsync 目录错误，请确认 SSH 用户对 `/opt` 有写权限（一般用 root）。

常用环境变量：`NW_DEPLOY_HOST`（默认 `new-world-kr-01.2fish.com.cn`）、`NW_REMOTE_DIR`（默认 `/opt/nwvpn`）、`NW_GO_VERSION`、`GOPROXY`、**`NW_DEPLOY_NAT`**（默认 `1`：远程启用 `ip_forward` + nft/iptables MASQUERADE；`0` 关闭）、**`NW_TUN_CIDR`**（默认 `10.77.0.0/24`）。远程日志：`ssh root@<主机> 'tail -f /opt/nwvpn/nw-server.log'`。**勿将密码写入仓库**；生产证书请自行替换 `certs/` 后再同步。

**Ubuntu 24.04**：脚本已按该环境核对——远程为 **Linux** 即可（脚本内会校验 `uname`）；编译使用 **`CGO_ENABLED=0`**，无需 `build-essential`。若你**在 Ubuntu 24.04 上运行本脚本**（作为 SSH 客户端），请安装：`sudo apt install -y openssh-client rsync`。**远程**若为最小化云镜像，常见需补：`sudo apt install -y rsync`（以及通常已带的 `curl`）。启用 UFW 时另需放行：`sudo ufw allow 8443/tcp`（或按你的端口改规则）。

**可选参数**（摘录，完整见 `go/cmd` 内 `flag` 定义与 `docs/server-deploy.md`）：

| 组件 | 常用参数 |
|------|-----------|
| `nw-server` | `-auth-file`、`-client-ca`、`-tun-cidr`、`-ifname` |
| `nw-client` | `-auth-file`、`-split-default`、`-insecure`（仅调试） |

**单元测试**：

```bash
cd go
go test ./...
```

**Windows 客户端**：在同一仓库 `go` 目录下于 Windows 中执行 `go build -o nw-client.exe ./cmd/nw-client`；将官方 **Wintun** 提供的 `wintun.dll`（与架构一致）放在 `nw-client.exe` 同目录，详见 `docs/signing-and-ops.md`。

---

## 3. macOS：图形壳 `SimpleConnect`

依赖本机 Xcode 命令行工具 / Swift，且需已编译好的 `nw-client`：

```bash
cd simple-connect
# 默认会查找 ../go/nw-client，也可用环境变量指定：
# export NW_CLIENT=/绝对路径/nw-client
sudo swift run
```

先编译再运行二进制（产物在 `.build/`）：

```bash
cd simple-connect
swift build -c release
sudo .build/release/SimpleConnect
```

说明见 [`simple-connect/README.md`](simple-connect/README.md)。

---

## 4. macOS：Xcode 应用 `NWVPN`（主应用 + Packet Tunnel）

用 XcodeGen 生成工程后再用 Xcode 打开、签名、运行：

```bash
brew install xcodegen   # 若未安装
cd apps/macos/NWVPN
xcodegen generate
open NWVPN.xcodeproj
```

仅验证编译（无签名，本地 CI 常用）：

```bash
cd apps/macos/NWVPN
xcodegen generate
xcodebuild -scheme NWVPN -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

说明与 Apple Developer 配置见 [`apps/macos/NWVPN/README.md`](apps/macos/NWVPN/README.md)。

---

## 5. Swift 包 `apple/`（协议库 + NWTunnel）

```bash
cd apple
swift build
swift test
```

在 Xcode 中可将 `apple/Package.swift` 作为本地 Swift Package 引用到其他工程。

---

## 6. Android

本仓库 `android/` 为 Gradle Kotlin DSL 工程。若目录下尚无 `gradlew`，可用 Android Studio 打开 **`android`** 同步后构建，或在已安装 Gradle 的前提下于 `android/` 执行：

```bash
cd android
gradle assembleDebug
# 若已生成 Gradle Wrapper，则推荐：
# ./gradlew assembleDebug
```

调试包一般在 `android/app/build/outputs/apk/debug/` 下（常见文件名为 `app-debug.apk`，以 Gradle 输出为准）。

---

## 7. 配置示例

- 服务端用户表：[`configs/auth.server.example.json`](configs/auth.server.example.json)  
- 客户端凭据：[`configs/auth.client.example.json`](configs/auth.client.example.json)  

复制为实际路径后，通过 `-auth-file` 传给 `nw-server` / `nw-client`。

---

## 8. 脚本与文档索引

| 路径 | 用途 |
|------|------|
| `scripts/gen-certs.sh` | 生成本地自签服务端/客户端证书 |
| `scripts/deploy-nw-server.sh` | SSH 部署远程 `nw-server`（检查/安装 Go、同步、编译、后台启动） |
| `docs/server-deploy.md` | 服务端部署、NAT、systemd、认证 |
| `docs/signing-and-ops.md` | 签名、Network Extension、Wintun、排障 |
| `docs/protocol-v1.md` | 帧协议 v1 |
