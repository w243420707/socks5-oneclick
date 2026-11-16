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

这不是选哪个软件的问题。换 Dante 也一样——它有个 `udp.portrange` 参数，手册写的是「指定 socks 客户端与 Dante 服务器之间传输 UDP 包所用的端口段」，同样不是代理端口。

### 诊断：中继端口到底是多少

```sh
python3 probe-udp.py --port 1080 --user 用户名 --pass 密码
```

脚本会完整走一遍协商和 UDP ASSOCIATE，直接打印服务器返回的地址和端口，并判断它和代理端口是否相同。对着老方案（Dante）和 gost 各跑一次，就能看出差别在哪。

Alpine 上若没有 python3：`apk add python3`。

### 三种 Go 代理的实测结果

| 代理 | 版本 | UDP ASSOCIATE 返回 |
|---|---|---|
| gost | 3.3.3 | 随机高位端口（实测 61277） |
| sing-box | 1.14.4 | 随机高位端口（实测 51165） |
| xray | 26.11.9 | 随机高位端口（实测 49675） |

三个都是随机端口，说明这是 Go 系代理的通行做法，不是某个软件的缺陷。

**待确认**：有反馈说老脚本的 Dante 在单端口环境下 UDP 是通的。如果属实，说明 Dante 的中继端口行为和上面三个不同。用 `probe-udp.py` 对着老 Dante 跑一次即可确认。

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

一条命令：

```sh
curl -fsSL -o /usr/local/bin/socks5 \
  https://github.com/w243420707/socks5-oneclick/releases/download/install/socks.sh \
  && chmod +x /usr/local/bin/socks5 && socks5
```

脚本会留在 `/usr/local/bin/socks5`，之后直接 `socks5 --status` 看状态，不用再下载。

跑起来会提示输入监听端口（默认 1080，重装时沿用上次的），然后自动：

> **不要用 `curl ... | sh`。** 管道会把标准输入占掉，端口提示读不到你的输入，只能走默认值。

国内访问慢的话用 CDN 镜像：

```sh
curl -fsSL -o /usr/local/bin/socks5 \
  https://cdn.jsdelivr.net/gh/w243420707/socks5-oneclick@main/socks.sh \
  && chmod +x /usr/local/bin/socks5 && socks5
```

不想交互，直接指定端口：

```sh
PORT=1080 socks5
```

也可以自己下载脚本再跑（`sh socks.sh`），效果一样。

装完自动做的事：
1. 识别架构，下载对应版本的 gost 并校验 sha256
2. 生成账号密码（重装时沿用已有凭据）
3. 写配置到 `/etc/gost/config.yaml`（权限 600）
4. 装好 systemd 或 OpenRC 服务并设为开机自启
5. 验证 TCP 监听和认证是否真的生效
6. 启用每小时自检

### 账号密码怎么来的

每次安装现场生成，不是写死的：

| 项 | 规则 |
|---|---|
| 用户名 | `socks` + 6 位 `[a-z0-9]` |
| 密码 | 16 位 `[A-Za-z0-9]`，取自 `/dev/urandom` |

重装会沿用已有凭据（`/etc/gost/gost.env`），要换用 `socks5 --rotate`。

认证是强制的：任何连接都必须带用户名密码，脚本装完会自动反向验证一次「不带凭据的请求被拒绝」。

### 密码不会被同机其他人看到

常见的教程写法是：

```sh
gost -L "socks5://user:pass@:1080"     # 不推荐
```

密码直接进命令行，`ps aux` 里裸奔，同一台机器上任何用户都能看到。

本脚本用配置文件传凭据，进程列表里只有 `-C /etc/gost/config.yaml`，看不到密码。配置文件权限 600，仅 root 可读。

### 风险边界

16 位大小写字母加数字，穷举不现实，扫描器撞不开。

真正的风险只有一个：**你自己把密码贴到公开的地方**。别贴截图、别把 `gost.env` 传到公开仓库、用完的临时笔记记得删。

### 装完看到什么

```
==================================================
安装完成！SOCKS5 代理（gost v3.3.3）
  地址     : 203.0.113.45
  端口     : 1080
  用户名   : socks7k2m9x
  密码     : Xq4Rt9WzLp2BvN6y
==================================================

一键链接（整行复制）：

socks5://socks7k2m9x:Xq4Rt9WzLp2BvN6y@203.0.113.45:1080

==================================================
```

链接单独占一行，选中整行就能复制，不用在终端里挑字。

`一键链接` 是标准的 `socks5://` URI，curl（`-x socks5h://...`）、SwitchyOmega、Proxifier、
系统代理设置这类地方可以直接填。

v2rayN / Clash 这类工具的分享格式和标准 URI 不同，通常要手动填地址、端口、用户名、密码四项。

四个字段也单独列出来了，凭据同时存在 `/etc/gost/gost.env`，随时可以用 `socks5 --status` 再查一遍，不会丢。

### 二进制从哪来

优先从**本仓库 Release** `gost-3.3.3` 下载（内含 amd64、arm64 两个架构，sha256 与 gost 官方 `checksums.txt` 一致）。本仓库没有对应架构时，自动回退到上游 `go-gost/gost` 的 Release。

> 本仓库需保持**公开**。私有状态下 Release 资源匿名下载会返回 404，自托管这条会失效，脚本只能回退上游。

想用镜像：`GOST_URL=<前缀> socks5`，前缀需能拼出 `<前缀>/gost_3.3.3_linux_<架构>.tar.gz` 和 `<前缀>/checksums.txt`。

## 用法

下面假设脚本已装到 `/usr/local/bin/socks5`。直接下载运行的，把 `socks5` 换成 `sh socks.sh`。

| 命令 | 作用 |
|---|---|
| `socks5` | 安装或重装，**保留**已有账号密码和端口 |
| `socks5 --rotate` | 安装并重置账号密码 |
| `socks5 --status` | 查看服务状态、TCP/UDP、连接数、内存占用 |
| `socks5 --help` | 帮助 |

### 环境变量

| 变量 | 说明 |
|---|---|
| `PORT` | 跳过交互，直接用指定端口。例：`PORT=1080 socks5` |
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

仓库里另有 `probe-udp.py`，用来诊断 SOCKS5 的 UDP 中继端口，见上文。

## 从旧版本升级

直接重跑新脚本即可。脚本会：

- 自动停用并禁用旧的 `danted` / `sockd` / `microsocks` 服务
- 删除旧脚本留下的 `/etc/socks5-proxy.env`（含旧凭据）
- **不会**卸载旧软件包，确认新方案稳定后自行清理，例如 `apk del dante-server`

旧方案的系统账号（`socksxxxxxx`）和新方案的凭据体系无关，可以手动删掉。

## 常用排查

```sh
socks5 --status                       # 一眼看状态
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

当前版本：**2.2.3**

### 2.2.3

**改进**
- 一键链接单独占一行，选中整行即可复制，不用在终端里挑字；`--status` 输出同样处理

**文档**
- 补充凭据生成规则、存储位置与风险边界
- 说明为何用配置文件而非命令行传密码（避免密码出现在 `ps aux`）

### 2.2.2

**修复**
- 安装完成的输出标题仍写着「TCP + UDP」，与实际行为不符，已去掉
- UDP 提示缩短，去掉过度绝对的表述，改为说明现象与稳妥做法

**文档**
- 增加安装输出示例，说明 `socks5://` 链接在哪些客户端可直接使用

### 2.2.1

**新增**
- 一键安装命令，脚本从 Release 的 `install` 标签下载（走 github.com 域名，不受 `raw.githubusercontent.com` 被墙影响），并落到 `/usr/local/bin/socks5`
- jsDelivr CDN 镜像命令，国内环境更快
- 明确提示不要用 `curl ... | sh`：管道会占掉标准输入，端口提示读不到

**改进**
- 脚本装成 `socks5` 后，帮助与结尾提示直接显示 `socks5 --status`，不再甩完整路径

### 2.2.0

**新增**
- `probe-udp.py`：诊断 SOCKS5 的 UDP 中继端口，完整走一遍协商与 UDP ASSOCIATE，打印服务器返回的地址端口并判断是否与代理端口相同
- README 补充 gost / sing-box / xray 三者的 UDP 中继端口实测结果

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
