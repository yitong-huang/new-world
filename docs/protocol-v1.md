# NewWorld VPN 应用层协议 v1

所有业务报文均在 **已建立的 TLS 1.3 连接的应用数据层** 内传输。TLS 提供机密性、完整性与（可选）双向证书认证。本层协议不定义自有加密算法。

## 字节序与常量

- 多字节整数均为 **大端（network byte order）**。
- **魔数** `magic`：`4E 57 30 31`（ASCII `NW01`）。
- **协议版本** `version`：当前为 `1`（`uint16`）。
- **最大帧长**（含帧头）：`1048576`（1 MiB）。实现必须在分配内存前校验 `length`。

## 帧格式（在 TLS 记录载荷内）

每帧结构固定为 12 字节头 + 变长载荷：

| 偏移 | 长度 | 字段 | 说明 |
|------|------|------|------|
| 0 | 4 | magic | 必须为 `NW01` |
| 4 | 2 | version | 必须为 `1` |
| 6 | 1 | msg_type | 见下表 |
| 7 | 1 | reserved | 保留，必须为 `0` |
| 8 | 4 | length | **仅载荷** 的字节数，不含本帧头 |
| 12 | length | payload | 依 `msg_type` 解析 |

若 `length` 超过实现允许的最大值，必须丢弃连接。

## 消息类型 `msg_type`

| 值 | 名称 | 方向 | 说明 |
|----|------|------|------|
| 1 | ClientHello | C→S | 客户端能力与期望 MTU |
| 2 | ServerHello | S→C | 服务端能力与协商 MTU |
| 3 | AssignTunnel | S→C | 下发虚拟 IPv4、DNS、标志 |
| 4 | Data | 双向 | 完整 L3 IPv4/IPv6 包（含 IP 头） |
| 5 | Keepalive | 双向 | 心跳，载荷可为空 |
| 6 | Error | 双向 | 错误码 + UTF-8 文本 |
| 7 | Disconnect | 双向 | 单字节 reason 后可选 UTF-8 说明 |
| 8 | AuthCredentials | C→S | 用户名 + 密码（UTF-8），见下；仅在 TLS 内传输 |

## 载荷布局

### ClientHello（type=1）

| 字段 | 类型 | 说明 |
|------|------|------|
| mtu | uint16 | 客户端期望隧道 MTU，可为 `0` 表示由服务端决定 |
| caps | uint32 | 能力位：bit0=要求全隧道（可选）；**bit1（`1<<1`）= 下一帧将发送 `AuthCredentials`**（在服务端未启用账号文件时，服务端仍会读取并丢弃该帧以保持握手对齐） |

### AuthCredentials（type=8）

| 字段 | 类型 | 说明 |
|------|------|------|
| user_len | uint16 | 用户名 UTF-8 字节数，≤512 |
| user | user_len | UTF-8 |
| pass_len | uint16 | 密码 UTF-8 字节数，≤512 |
| pass | pass_len | UTF-8 |

### ServerHello（type=2）

| 字段 | 类型 | 说明 |
|------|------|------|
| mtu | uint16 | 协商后的隧道 MTU |
| caps | uint32 | 服务端能力位（与 ClientHello 对齐的语义） |

### AssignTunnel（type=3）

| 字段 | 类型 | 说明 |
|------|------|------|
| ipv4 | 4 bytes | 分配给客户端的虚拟 IPv4（大端） |
| dns_count | uint8 | 紧随其后的 DNS IPv4 个数，≤4 |
| dns | 4 × dns_count | 每个 DNS 为 4 字节 IPv4 |
| flags | uint8 | bit0=1 表示「全隧道」默认路由由客户端解释 |

### Data（type=4）

载荷为 **一个完整的 IP 数据报**（IPv4 或 IPv6），从版本字段开始，与内核 TUN 读写格式一致。

### Keepalive（type=5）

载荷长度可为 `0`。若为非零，可为实现自定义扩展（首版应忽略附加字节或整体拒帧——实现应一致）。

### Error（type=6）

| 字段 | 类型 | 说明 |
|------|------|------|
| code | uint16 | 错误码 |
| msg_len | uint16 | 后续 UTF-8 字节数 |
| msg | msg_len | UTF-8 文本 |

建议错误码：`1` 协议/帧错误，`2` 资源耗尽（如地址池用尽），**`3` 鉴权失败**（用户名密码不匹配或载荷非法）。

### Disconnect（type=7）

| 字段 | 类型 | 说明 |
|------|------|------|
| reason | uint8 | 关闭原因枚举 |
| msg_len | uint16 | 可选说明长度 |
| msg | msg_len | 可选 UTF-8 |

**reason**：`0`=正常关闭，`1`=协议错误，`2`=鉴权失败，`3`=空闲超时，`255`=其他。

## 连接状态机（简）

1. TCP 连接建立并完成 TLS 握手。
2. 客户端发送 **ClientHello**（若将发送凭据，置 `caps` 的 bit1，并紧接发送 **AuthCredentials**）。
3. **若服务端配置了用户表**：在 **ClientHello** 之后**必须**收到 **AuthCredentials**，校验通过后再回复 **ServerHello**；失败则回复 **Error**（建议 code=`3`）并关闭。
4. **若服务端未配置用户表**且 `ClientHello.caps` 含 bit1：读取并丢弃一帧 **AuthCredentials**（用于与已启用客户端凭据的旧客户端对齐）；若声明了 bit1但下一帧不是 AuthCredentials，应报错断开。
5. 服务端回复 **ServerHello**，再发送 **AssignTunnel**。
6. 双方可收发 **Data**、**Keepalive**。
7. 任一方可发送 **Error** / **Disconnect** 后关闭 TLS。

服务端在收到 ClientHello 之前收到其它类型：应发送 Error（code=协议错误）并断开。

### 配置文件约定（实现参考）

- **服务端**：JSON 文件，形如 [`configs/auth.server.example.json`](../configs/auth.server.example.json)，启动参数例如 `-auth-file=/etc/nw/auth.json`。
- **客户端**：JSON 文件，形如 [`configs/auth.client.example.json`](../configs/auth.client.example.json)，启动参数例如 `-auth-file=.../auth.client.json`。

## 与 `proto/nw.proto` 的关系

`.proto` 仅描述 **逻辑消息** 的字段，便于代码生成与文档对齐；**线格式以本文档的帧头 + 二进制载荷为准**。若生成代码与本文冲突，以本文为准。

## 安全注意

- 限制单连接帧率与带宽；校验 `length`。
- 客户端应对服务端证书做主机名/固定公钥校验（证书固定 pin 可用于内网）。
