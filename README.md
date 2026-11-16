# socks5-oneclick

一条命令在 Alpine / Debian / Ubuntu 上装好带账号密码认证的 SOCKS5 代理，底层用 [gost](https://github.com/go-gost/gost) v3 单进程实现——连接数再多，内存也不会跟着涨。

---

## 先说清楚 UDP 的真相

**标准 SOCKS5 的 UDP 不走你那个代理端口。** 协议规定：客户端发起 UDP ASSOCIATE 协商后，服务器回一个**按需分配的高位端口**，之后客户端把 UDP 包发到那个端口。

实测 gost 3.3.3 返回的是随机端口：

```
协商 0502 → 认证 0100 → UDP ASSOCIATE → BND=127.0.0.1:61277
```

gost 官方参数表里也没有任何选项能固定这个端口。

所以能不能用，取决于你的入口：

| 场景 | UDP 能用吗 |
|---|---|
| 公网 VPS，能放行一整段 UDP 端口 | 能，标准客户端直接用 |
| 入场只映射一个端口的 NAT 小鸡 | **不能**，包在你上游就被丢了 |
| NAT 小鸡 + 客户端也跑 gost | 能，UDP 走 TCP 隧道（见下） |

这不是选哪个软件的问题。换 Dante 也一样——它有个 `udp.portrange` 参数指定 UDP 转发端口段，同样不是代理端口。

### UDP 走 TCP 隧道（NAT 小鸡的解法）

在客户端也装一份 gost，把 UDP 塞进 TCP 连接里，服务端就不需要任何额外端口：

```sh
gost -L "udp://127.0.0.1:5353/8.8.8.8:53" \
     -F "socks5://用户名:密码@你的IP:端口"
```

然后把应用里的 DNS 指向 `127.0.0.1:5353`。目标地址按需替换成你实际要访问的 UDP 服务。

**原理**：gost 客户端默认用 UDP-over-TCP 隧道（`relay` 未开启时）。实测这种模式下服务端只绑一个 TCP 端口，一个 UDP 套接字都没有。

代价：这是**按目标转发**，不是给任意客户端提供一个 UDP 出口。要让浏览器、Clash 这类标准客户端直接用 UDP，还是得放行高位端口段。

## 为什么不用 Dante

老版本脚本用 Dante，它每条连接 fork 一个子进程：

```
内存 ≈ 5 MB + 连接数 × 3 MB
```

200 条并发连接就是 600 MB 以上，而且 Dante 没有连接池、没有并发上限指令，调参只能延缓爆点。gost 是单进程 + 协程模型，每条连接只多几 KB，200 条连接总占用也就 20 MB 上下。

## 安装

```sh
sh socks.sh
```

会提示输入监听端口（默认 1080，重装时沿用上次的），然后自动：

1. 识别架构，下载对应版本的 gost 并校验 sha256
2. 生成账号密码（重装时沿用已有凭据）
3. 写配置到 `/etc/gost/config.yaml`（权限 600）
4. 装好 systemd 或 OpenRC 服务并设为开机自启
5. 验证 TCP 监听和认证是否真的生效
6. 启用每小时自检

### 二进制从哪来

优先从**本仓库 Release** `gost-3.3.3` 下载（内含 amd64、arm64 两个架构，sha256 与 gost 官方 `checksums.txt` 一致）。本仓库没有对应架构时，自动回退到上游 `go-gost/gost` 的 Release。

想用镜像：`GOST_URL=<前缀> sh socks.sh`，前缀需能拼出 `<前缀>/gost_3.3.3_linux_<架构>.tar.gz` 和 `<前缀>/checksums.txt`。

## 用法

| 命令 | 作用 |
|---|---|
| `sh socks.sh` | 安装或重装，**保留**已有账号密码和端口 |
| `sh socks.sh --rotate` | 安装并重置账号密码 |
| `sh socks.sh --status` | 查看服务状态、TCP/UDP、连接数、内存占用 |
| `sh socks.sh --help` | 帮助 |

### 环境变量

| 变量 | 说明 |
|---|---|
| `PORT` | 跳过交互，直接用指定端口。例：`PORT=1080 sh socks.sh` |
| `GOST_ARCH` | 强制指定架构，如 `amd64v3`、`arm64` |
| `GOST_URL` | 镜像下载前缀 |

## 文件位置

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/gost` | 程序本体（约 50 MB） |
| `/etc/gost/config.yaml` | gost 配置（含账号密码，600） |
| `/etc/gost/gost.env` | 端口与凭据记录（600），`--status` 读这个 |
| `/etc/systemd/system/gost.service` | systemd 单元（Debian / Ubuntu） |
| `/etc/init.d/gost` | OpenRC 服务（Alpine） |
| `/usr/local/bin/socks5-watchdog.sh` | 每小时自检脚本 |

## 从旧版本升级

直接重跑新脚本即可。脚本会：

- 自动停用并禁用旧的 `danted` / `sockd` / `microsocks` 服务
- 删除旧脚本留下的 `/etc/socks5-proxy.env`（含旧凭据）
- **不会**卸载旧软件包，确认新方案稳定后自行清理，例如 `apk del dante-server`

旧方案的系统账号（`socksxxxxxx`）和新方案的凭据体系无关，可以手动删掉。

## 常用排查

```sh
sh socks.sh --status                  # 一眼看状态
journalctl -u gost -n 50              # Debian / Ubuntu 看日志
tail -n 50 /var/log/messages          # Alpine 看日志
ss -lntup | grep <端口>                # 确认 TCP 监听
```

**TCP 连不上**：先看 `--status` 服务是否 active，再看安全组是否放行该端口。

**UDP 不通**：先确认你的入口是不是只映射了一个端口。是的话标准 SOCKS5 UDP 必然失败，走上面「UDP 走 TCP 隧道」。

## 环境要求

- root 权限
- 能访问 GitHub（下载 gost）；不通时用 `GOST_URL` 指定镜像
- Alpine 或 Debian / Ubuntu 系

## 版本与更新日志

当前版本：**2.1.0**

### 2.1.0

**修正**
- **UDP 说明纠正**：标准 SOCKS5 的 UDP 使用按需分配的高位端口，不是代理端口。2.0.0 声称「单端口同时承载 TCP 与 UDP」是错误的，实测 gost 返回随机端口
- `--status` 的 UDP 一行改为反映真实状态（固定监听 / 按需分配），不再误报「未监听」
- 安装完成后不再提示「放行 UDP」，改为说明 TCP 隧道的用法

**新增**
- 二进制优先从本仓库 Release `gost-3.3.3` 下载，缺失时回退上游；自托管包校验失败直接中止，不降级
- 安装完成后打印 gost 客户端 UDP 隧道命令

### 2.0.0

**架构**：Dante / microsocks 双方案改为 gost v3 单进程，修复连接数升高后内存线性增长（原模型约 3 MB/连接）。

**新增**
- `--status` 子命令：服务状态、TCP/UDP、连接数、内存占用、凭据与链接
- `--rotate`：重置账号密码
- `PORT` / `GOST_ARCH` / `GOST_URL` 环境变量
- 下载时用官方 `checksums.txt` 校验 sha256
- 重装时**复用**已有账号密码，不再每次生成新凭据
- 升级时自动停用旧的 danted / sockd / microsocks 服务
- `GOMEMLIMIT=64MiB`，压住 Go 在小内存机器上的 GC 峰值
- `RestartSec=3` + `StartLimitBurst=5`，避免端口冲突时的高速重启循环

**移除**
- Dante、microsocks 全部安装与回退逻辑
- PAM 配置、创建系统账号、源码编译分支

**修复**
- 旧版 OpenRC microsocks 单元声明了 `command_user="nobody"` 但实际以 root 运行
- 旧版凭据文件缺失时 microsocks 会退化成无认证的开放代理

### 1.0.0

初始版本：Dante 优先、microsocks 回退，强制账号密码认证，开机自启，每小时自检。
