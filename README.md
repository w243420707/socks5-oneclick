# socks5-oneclick

一条命令在 Alpine / Debian / Ubuntu 上装好带账号密码认证的 SOCKS5 代理，**TCP 和 UDP 共用一个端口**。

底层用 [gost](https://github.com/go-gost/gost) v3 单进程实现——连接数再多，内存也不会跟着涨。

---

## 为什么不用 Dante

老版本脚本用 Dante，它每条连接 fork 一个子进程：

```
内存 ≈ 5 MB + 连接数 × 3 MB
```

200 条并发连接就是 600 MB 以上，而且 Dante 没有连接池、没有并发上限指令，调参只能延缓爆点。

gost 是单进程 + 协程模型，每条连接只多几 KB，200 条连接总占用也就 20 MB 上下，且与连接数基本无关。

## 安装

```sh
sh socks.sh
```

会提示输入监听端口（默认 1080，重装时沿用上次的端口），然后自动：

1. 识别架构，下载对应版本的 gost 并用官方 `checksums.txt` 校验 sha256
2. 生成账号密码（重装时沿用已有凭据）
3. 写配置到 `/etc/gost/config.yaml`（权限 600）
4. 装好 systemd 或 OpenRC 服务并设为开机自启
5. 验证 TCP / UDP 监听和认证是否真的生效
6. 启用每小时自检

### 装完必须做的一件事

去云厂商安全组放行**同一个端口的 TCP 和 UDP**。

只放 TCP 的话，普通网页代理能用，但所有 UDP 业务会失败。

## 用法

| 命令 | 作用 |
|---|---|
| `sh socks.sh` | 安装或重装，**保留**已有账号密码和端口 |
| `sh socks.sh --rotate` | 安装并重置账号密码 |
| `sh socks.sh --status` | 查看服务状态、TCP/UDP 监听、当前连接数、内存占用 |
| `sh socks.sh --help` | 帮助 |

### 环境变量

| 变量 | 说明 |
|---|---|
| `PORT` | 跳过交互，直接用指定端口。例：`PORT=1080 sh socks.sh` |
| `GOST_ARCH` | 强制指定架构，如 `amd64v3`、`arm64` |
| `GOST_URL` | 镜像下载前缀，需能拼出 `<前缀>/gost_<版本>_linux_<架构>.tar.gz` |

## 文件位置

| 路径 | 说明 |
|---|---|
| `/usr/local/bin/gost` | 程序本体 |
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

注意：旧方案的系统账号（`socksxxxxxx`）和新方案的凭据体系无关，可以手动删掉。

## 常用排查

```sh
sh socks.sh --status                  # 一眼看状态
journalctl -u gost -n 50              # Debian / Ubuntu 看日志
tail -n 50 /var/log/messages          # Alpine 看日志
ss -lntup | grep <端口>                # 确认 TCP 和 UDP 都在监听
```

**UDP 不通怎么查**

1. `--status` 里 UDP 是不是「监听中」，不是就是配置没生效
2. 安全组有没有放行 UDP
3. 客户端本身支不支持 SOCKS5 的 UDP ASSOCIATE——浏览器扩展很多不支持

## 环境要求

- root 权限
- 能访问 GitHub（下载 gost）；不通时用 `GOST_URL` 指定镜像
- Alpine 或 Debian / Ubuntu 系

## 版本与更新日志

当前版本：**2.0.0**

### 2.0.0

**架构**：Dante / microsocks 双方案改为 gost v3 单进程。
修复连接数升高后内存线性增长的问题（原模型约 3 MB/连接）。

**新增**
- `--status` 子命令：服务状态、TCP/UDP 监听、连接数、内存占用、凭据与链接
- `--rotate`：重置账号密码
- `PORT` / `GOST_ARCH` / `GOST_URL` 环境变量
- 下载时用官方 `checksums.txt` 校验 sha256
- 启动后自动验证 UDP 是否监听
- 重装时**复用**已有账号密码，不再每次生成新凭据
- 升级时自动停用旧的 danted / sockd / microsocks 服务
- `GOMEMLIMIT=64MiB`，压住 Go 在小内存机器上的 GC 峰值
- `RestartSec=3` + `StartLimitBurst=5`，避免端口冲突时的高速重启循环

**移除**
- Dante、microsocks 全部安装与回退逻辑
- PAM 配置（`/etc/pam.d/sockd`）
- 创建系统账号（不再污染 `/etc/passwd`）
- 源码编译分支（不再需要 `build-base` / `build-essential`）
- `/tmp/microsocks.*` 残留问题

**修复**
- 旧版 OpenRC microsocks 单元声明了 `command_user="nobody"` 但实际以 root 运行
- 旧版凭据文件缺失时 microsocks 会退化成无认证的开放代理

### 1.0.0

初始版本：Dante 优先、microsocks 回退，强制账号密码认证，开机自启，每小时自检。
