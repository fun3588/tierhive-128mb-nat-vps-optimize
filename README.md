# TierHive 128MB NAT VPS 极致优化 + EasyTier 组网

![Alpine Linux](https://img.shields.io/badge/Alpine%20Linux-3.23%20%2F%203.24-blueviolet?style=flat-square)
![RAM](https://img.shields.io/badge/RAM-128MB-orange?style=flat-square)
![Disk](https://img.shields.io/badge/Disk-953MB-yellow?style=flat-square)
![EasyTier](https://img.shields.io/badge/EasyTier-v2.6.4-green?style=flat-square)
![webhook-tester](https://img.shields.io/badge/webhook--tester-v2.3.0-teal?style=flat-square)
![License](https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square)

---

一套针对 **TierHive 128MB NAT KVM VPS** 的 Alpine Linux 极限瘦身方案，并在其上部署 **EasyTier** 全网格 P2P VPN，把没有公网 IP 的小鸡接入统一内网。

## 目录

- [背景与目标](#背景与目标)
- [优化效果一览](#优化效果一览)
- [为什么要安装 EasyTier](#为什么要安装-easytier)
- [优化项详解](#优化项详解)
- [EasyTier 部署](#easytier-部署)
- [Test Lite 精简测评工具包](#test-lite-精简测评工具包)
- [Webhook 调试：webhook-tester](#webhook-调试webhook-tester)
- [文件说明](#文件说明)
- [快速复现](#快速复现)
- [实测数据](#实测数据)
- [注意事项](#注意事项)

---

## 背景与目标

TierHive 的 128MB NAT VPS 配置极为紧凑：

| 规格 | 数值 |
|---|---|
| CPU | 1 vCore（AMD EPYC 7763） |
| 内存 | 93 MiB 可用（标称 128MB） |
| Swap | 128 MiB zram |
| 磁盘 | 953 MiB（virtio-blk `/dev/vda`） |
| 网络 | NAT，内网 `10.20.5.x`，无公网 IPv4 |
| 系统 | Alpine Linux（musl + busybox） |

出厂即启用 zram 以便 `apk` 能在极小内存下完成安装，但 `apk` 溢出会导致重启后系统损坏——所以**系统必须足够瘦**，同时任何依赖（如 VPN）也必须足够轻。

目标：

1. 把内存和磁盘占用压到最低，留出足够余量跑业务；
2. 通过 EasyTier 把这台 NAT 小鸡接入全网，免公网 IP 也能直连；
3. 用定时任务自动清理与自愈，长期无需人工干预。

---

## 优化效果一览

| 指标 | 优化前 | 优化后 | 变化 |
|---|---:|---:|---|
| 磁盘占用 | 165–210 MB | **101–144 MB** | ↓ 40% |
| 已安装包 | 200+ | **75** | ↓ 62% |
| 加载内核模块 | 25–28 | **21** | ↓ 25% |
| 开机服务 | 6 | **4–5** | 精简 |
| 空闲可用内存 | ~35 MB | **~29–33 MB**（含 EasyTier） | 更健康 |
| IPv6 | 启用 | **内核级禁用** | 省线程/内存 |
| 日志 | 落盘 | **内存环形缓冲 + 轮转** | 免磁盘写 |

---

## 为什么要安装 EasyTier

这台 VPS 处于 **NAT 网络**，没有公网 IPv4，常规 SSH / 服务暴露都做不到。EasyTier 解决的问题：

- **穿透 NAT 组网**：全网格 P2P，节点间优先直连，打不通才中继；
- **无需公网 IP**：只要能出网即可加入网络，分配虚拟 IP（`10.126.126.x`）；
- **轻量**：单个静态二进制，RSS 约 6 MB，完美适配 128MB 小鸡；
- **加密与认证**：`network_name` + `network_secret` 控制接入，流量加密；
- **自愈**：配合定时脚本，掉线自动拉起；
- **统一管理**：多台小鸡、家用机、云主机在同一内网互相直连，SSH / 文件同步 / 反向代理都方便。

实际效果：本机与日本、欧洲的多台 NAT VPS 组成同一内网，`ssh root@10.126.126.5` 直接登录，延迟约 60–300 ms（视节点位置），无需公网 IP、无需端口映射、无需代理。

> 对比：公网直连 SSH 会被 GFW 干扰（TCP 握手成功但无 SSH banner），而 EasyTier 内网直连稳定可用。

---

## 优化项详解

### 阶段一：内核与引导

**1. 内核模块黑名单**（`blacklist-unnecessary.conf`）

屏蔽无头 VPS 上永远不会用到的驱动：显卡（drm/fb/virtio_gpu）、KVM 嵌套、光驱/软驱、USB、I2C、HID 输入设备、错误云厂商驱动（gve/ena）等。对 DRM 类使用 `install <module> /bin/true` 强制阻断（仅 blacklist 会被 ACPI 触发绕过）。

保留 `virtio_balloon` 与 `loop`——本机 zram 依赖相关块设备链路。

**2. 引导参数**（`/boot/extlinux.conf` + `/etc/update-extlinux.conf`）

```
ipv6.disable=1 audit=0 nowatchdog
```

- `ipv6.disable=1`：内核级关闭 IPv6，省去相关线程与内存分配；
- `audit=0`：关闭审计子系统（VPS 无意义）；
- `nowatchdog`：关闭 soft/hard lockup 检测线程。

**3. initramfs 精简**

`features="base ext4 virtio"`，移除 USB / CDROM / NVMe / RAID / 云厂商驱动。

**4. 配套处理**

- 注释 `00-alpine.conf` 中的 IPv6 sysctl（内核栈已移除，避免启动报错）；
- 禁止 `debugfs` / `tracefs` 挂载；
- 重建 `mkinitfs`。

### 阶段二：包清理

删除一次性组件：

```sh
# cloud-init 及其 Python 依赖（首次启动后无用）
apk del $(grep '^P:' /lib/apk/db/installed | sed 's/^P://' \
  | grep -E '^(cloud-init|cloud-utils|py3-|python3|pyc)')

# 运行期无用工具
apk del bash sudo doas syslinux mtools numactl e2fsprogs-extra partx

# 孤儿库
apk del readline gdbm mpdecimal sqlite-libs yaml p11-kit libtasn1 \
  gnutls nettle gmp libidn2 libunistring libexpat libedit libffi \
  libseccomp libncursesw libpanelw ncurses-terminfo-base

rm -rf /var/cache/apk/*
```

**刻意保留**：`openssh`（管理入口）、`curl`（下载/测速）、`tzdata`（时区）、`logrotate`（日志轮转）、`zram` 相关（`local.d/zram.start`）。

> 未采用 Dropbear 替换 OpenSSH：本环境经代理连接，切换 SSH 服务有失联风险，且实测 sshd 常驻仅约 3 MB，收益有限。

### 阶段三：服务与系统调优

- 停用 `ntpd`（KVM `kvm-clock` 已授时）、`acpid`、`hwclock`；
- syslog 改为内存环形缓冲：`SYSLOGD_OPTS="-t -C64"`，用 `logread` 查看；
- sysctl 调优（`10-minvps.conf`）：缩小 socket 缓冲、加快 inode/dentry 回收、降低 `pid_max`、调整脏页阈值；
- 块设备预读降至 128KB；
- **保留 zram**：apk 操作依赖 swap 支撑，禁用会导致升级失败。

### 阶段四：日常维护脚本

`optimize.sh`（幂等，设计为每小时 cron 执行）：

- 清理 apk 缓存与 `/tmp` 陈旧文件；
- 日志轮转（`logrotate`）；
- 重设 readahead 与 sysctl；
- **zram 掉线自动恢复**；
- **EasyTier 掉线自动拉起**；
- 回收页面缓存；
- 资源快照写入 `/var/log/optimize.log`。

定时任务：

```
0 * * * * /root/optimize.sh >/dev/null 2>&1
```

---

## EasyTier 部署

下载官方静态二进制（musl 兼容，x86_64），校验 SHA256 后安装到 `/usr/local/bin`：

```sh
curl -fsSL -o easytier.zip \
  https://github.com/EasyTier/EasyTier/releases/download/v2.6.4/easytier-linux-x86_64-v2.6.4.zip
# SHA256: 61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6
python3 -c "import zipfile; zipfile.ZipFile('/tmp/easytier.zip').extractall('/tmp/et-pkg')"
install -m 755 /tmp/et-pkg/easytier-linux-x86_64/easytier-* /usr/local/bin/
```

配置见 [`easytier-config.toml.example`](easytier-config.toml.example)（已脱敏）。OpenRC 服务文件见 [`easytier-openrc`](easytier-openrc)，加入开机自启：

```sh
rc-update add easytier default
rc-service easytier start
```

验证：

```sh
easytier-cli node    # 查看本机虚拟 IP / 主机名
easytier-cli peer    # 查看组网节点与延迟
```

---

## Test Lite 精简测评工具包

`test-lite/` 是专为 **TierHive 128MB NAT VPS** 编写的精简测评工具：纯 busybox、零安装，覆盖测速、流媒体可访问性、IP 质量、路由追踪和本地性能测试。所有联网请求都是只读 GET，没有 POST、没有 paste、没有遥测，报告只写本机。测完自动生成 Markdown 报告并清理临时文件。适用于 Alpine 3.23.8 / 3.24.4，额外内存约 2–4 MB。

```sh
sh test-lite/test-lite.sh             # 全测并生成 /root/test-lite-report.md
sh test-lite/test-lite.sh net         # 只跑测速 + 解锁 + IP + 路由
```

详见 [`test-lite/README.md`](test-lite/README.md)。

---

## Webhook 调试：webhook-tester

在 128MB 小鸡上需要接收/调试 Webhook（GitHub、GitLab、各种回调）时，选用 [`webhook-tester`](https://github.com/tarampampam/webhook-tester)：生成随机 URL 接收 HTTP 请求，在内置 WebUI 实时查看请求内容、自定义响应码/头/体和延迟，是 `webhook.site` 的自托管替代。

它是 Go 单二进制，内置 React WebUI，无需外部依赖：二进制约 18 MB，运行时 RSS 约 12 MB，非常适合 128MB 小鸡长期运行。

**安装与运行**（v2.3.0，官方静态二进制，SHA256 已校验）：

```sh
curl -fsSL -o webhook-tester \
  https://github.com/tarampampam/webhook-tester/releases/download/v2.3.0/webhook-tester-linux-amd64
chmod +x webhook-tester
install -m 755 webhook-tester /usr/local/bin/webhook-tester
```

OpenRC 服务见 [`webhook-tester-openrc`](webhook-tester-openrc)，默认监听 `8081`：

```sh
rc-update add webhook-tester default
rc-service webhook-tester start
```

通过 EasyTier 内网访问 WebUI：`http://10.126.126.x:8081`。**已配置为 `fs` 持久化存储**（数据写在 `/var/lib/webhook-tester`，重启后请求记录保留）；服务文件里带 `--storage-driver fs --fs-storage-dir /var/lib/webhook-tester` 参数，该目录需预先创建。默认 `memory` 驱动会在重启后丢失数据，本机未采用。

---

## 文件说明

| 文件 | 用途 |
|---|---|
| `README.md` | 本文档 |
| `optimize.sh` | 日常优化维护脚本（每小时执行） |
| `blacklist-unnecessary.conf` | 内核模块黑名单 |
| `easytier-config.toml.example` | EasyTier 配置模板（脱敏） |
| `easytier-openrc` | EasyTier OpenRC 服务定义 |
| `webhook-tester-openrc` | webhook-tester OpenRC 服务定义（端口 8081） |
| `test-lite/` | Alpine 128MB 精简测评工具包（自带 README） |

---

## 快速复现

```sh
# 1) 内核层：放入 blacklist、改引导参数、注释 IPv6 sysctl、重建 initramfs
cp blacklist-unnecessary.conf /etc/modprobe.d/
sed -i 's/audit=0 nowatchdog/ipv6.disable=1 audit=0 nowatchdog/' /boot/extlinux.conf
mkinitfs

# 2) 包清理（见"阶段二"命令）

# 3) 安装 EasyTier 并配置（见上文）

# 4) 部署维护脚本与定时任务
install -m 755 optimize.sh /root/optimize.sh
(crontab -l; echo "0 * * * * /root/optimize.sh >/dev/null 2>&1") | crontab -

# 5) 重启使内核参数生效
reboot
```

重启后用 `easytier-cli node` 和 `free -m` 验证。

---

## 实测数据

**连接延迟**（本机 → 日本小鸡）：

| 方式 | SSH 完整登录+执行 |
|---|---:|
| EasyTier 内网 `10.126.126.5:22` | **~1.13 s** |
| 代理 → 公网 `4678` | ~2.08 s |

**服务器带宽**（东京节点）：

- 下载：约 9–11 Mbps（Cloudflare / Hetzner 实测）
- 到 Cloudflare：~8 ms；到国内 DNS：~83 ms

**组网**：6 个节点全部可见，P2P 直连优先，延迟 60–400 ms（视位置）。

---

## 注意事项

1. **版本差异**：TierHive 部分机器出厂为 Alpine 3.23.8，部分为 3.24.4；方案两者均适用。
2. **zram 不可禁用**：128MB 机器依赖 zram 完成 `apk` 操作，禁用会导致升级失败甚至系统损坏。
3. **instance_id 唯一性**：多台机器不要复用同一 `instance_id`；若冲突，改为新 UUID。
4. **SSH 服务**：保持 OpenSSH 而非 Dropbear，避免代理环境下失联。

---

A guide to aggressively slim down Alpine Linux on a **TierHive 128MB NAT KVM VPS**, and deploy **EasyTier** (a full-mesh P2P VPN) so that NAT boxes without a public IP can join a unified private network.

## Table of Contents

- [Background & Goals](#background--goals)
- [Optimization Results](#optimization-results)
- [Why EasyTier](#why-easytier)
- [Optimization Details](#optimization-details)
- [EasyTier Deployment](#easytier-deployment)
- [Test Lite Compact Toolkit](#test-lite-compact-toolkit)
- [Webhook Debugging: webhook-tester](#webhook-debugging-webhook-tester)
- [Files](#files)
- [Quick Reproduce](#quick-reproduce)
- [Benchmarks](#benchmarks)
- [Caveats](#caveats)

---

## Background & Goals

The TierHive 128MB NAT VPS is extremely tight:

| Spec | Value |
|---|---|
| CPU | 1 vCore (AMD EPYC 7763) |
| RAM | 93 MiB usable (128MB nominal) |
| Swap | 128 MiB zram |
| Disk | 953 MiB (virtio-blk `/dev/vda`) |
| Network | NAT, private `10.20.5.x`, no public IPv4 |
| OS | Alpine Linux (musl + busybox) |

zram is enabled from the factory so `apk` can complete under tiny memory, but an `apk` overflow will corrupt the system after reboot — so the **system must be lean**, and any dependency (such as a VPN) must be lightweight too.

Goals:

1. Minimize RAM and disk usage, leaving headroom for real workloads;
2. Use EasyTier to connect this NAT box into a private network, enabling direct access without a public IP;
3. Automate cleanup and self-healing via cron, requiring no manual intervention.

---

## Optimization Results

| Metric | Before | After | Change |
|---|---:|---:|---|
| Disk usage | 165–210 MB | **101–144 MB** | ↓ 40% |
| Installed packages | 200+ | **75** | ↓ 62% |
| Loaded kernel modules | 25–28 | **21** | ↓ 25% |
| Boot services | 6 | **4–5** | slimmed |
| Free RAM (idle) | ~35 MB | **~29–33 MB** (incl. EasyTier) | healthier |
| IPv6 | enabled | **disabled at kernel level** | fewer threads/memory |
| Logs | on-disk | **in-memory ring buffer + rotation** | no disk writes |

---

## Why EasyTier

This VPS sits behind **NAT** with no public IPv4, so conventional SSH / service exposure is impossible. EasyTier solves this:

- **NAT traversal**: full-mesh P2P — direct connections between peers preferred, relay only as fallback;
- **No public IP needed**: outbound access is enough to join, receives a virtual IP (`10.126.126.x`);
- **Lightweight**: a single static binary, ~6 MB RSS — a perfect fit for a 128MB box;
- **Encryption & auth**: `network_name` + `network_secret` gate access, traffic encrypted;
- **Self-healing**: paired with the cron script, auto-restarts on disconnect;
- **Unified management**: NAT boxes, home machines, and cloud hosts all directly reachable on one subnet — convenient for SSH, file sync, and reverse proxies.

Result: this host and several NAT VPSes in Japan and Europe form one subnet; `ssh root@10.126.126.5` just works at ~60–300 ms latency (depending on node), with no public IP, no port forwarding, and no proxy.

> Note: direct public SSH is disrupted by the GFW (TCP handshake succeeds but no SSH banner), while EasyTier private direct connections are stable.

---

## Optimization Details

### Stage 1: Kernel & Boot

**1. Kernel module blacklist** (`blacklist-unnecessary.conf`)

Block drivers never used on a headless VPS: graphics (drm/fb/virtio_gpu), KVM nesting, floppy/CDROM, USB, I2C, HID input, wrong cloud drivers (gve/ena), etc. For DRM modules use `install <module> /bin/true` to hard-block them (a plain blacklist can be bypassed by ACPI).

Keep `virtio_balloon` and `loop` — zram on this host depends on the related block-device chain.

**2. Boot parameters** (`/boot/extlinux.conf` + `/etc/update-extlinux.conf`)

```
ipv6.disable=1 audit=0 nowatchdog
```

- `ipv6.disable=1`: disable IPv6 at kernel level, saving threads and memory allocations;
- `audit=0`: disable the audit subsystem (useless on a VPS);
- `nowatchdog`: disable soft/hard lockup detector threads.

**3. Slim initramfs**

`features="base ext4 virtio"`, dropping USB / CDROM / NVMe / RAID / cloud drivers.

**4. Supporting changes**

- Comment out IPv6 sysctls in `00-alpine.conf` (kernel stack removed, avoid boot errors);
- Prevent `debugfs` / `tracefs` from mounting;
- Rebuild `mkinitfs`.

### Stage 2: Package Cleanup

Remove one-time components:

```sh
# cloud-init and its Python dependencies (useless after first boot)
apk del $(grep '^P:' /lib/apk/db/installed | sed 's/^P://' \
  | grep -E '^(cloud-init|cloud-utils|py3-|python3|pyc)')

# runtime-unused tools
apk del bash sudo doas syslinux mtools numactl e2fsprogs-extra partx

# orphaned libraries
apk del readline gdbm mpdecimal sqlite-libs yaml p11-kit libtasn1 \
  gnutls nettle gmp libidn2 libunistring libexpat libedit libffi \
  libseccomp libncursesw libpanelw ncurses-terminfo-base

rm -rf /var/cache/apk/*
```

**Deliberately kept**: `openssh` (management entry), `curl` (download/benchmark), `tzdata` (timezone), `logrotate` (log rotation), `zram` pieces (`local.d/zram.start`).

> Did not replace OpenSSH with Dropbear: this environment connects through a proxy, so switching SSH services risks losing access, and the measured resident size of sshd is only ~3 MB — limited benefit.

### Stage 3: Service & System Tuning

- Disable `ntpd` (KVM `kvm-clock` already keeps time), `acpid`, `hwclock`;
- syslog → in-memory ring buffer: `SYSLOGD_OPTS="-t -C64"`, view with `logread`;
- sysctl tuning (`10-minvps.conf`): smaller socket buffers, faster inode/dentry reclaim, lower `pid_max`, tuned dirty-page thresholds;
- Block-device read-ahead reduced to 128 KB;
- **Keep zram**: `apk` operations depend on swap support; disabling it causes upgrade failures.

### Stage 4: Daily Maintenance Script

`optimize.sh` (idempotent, designed for hourly cron execution):

- Clean apk cache and stale `/tmp` files;
- Log rotation (`logrotate`);
- Re-apply readahead and sysctl;
- **Auto-recover zram if it drops**;
- **Auto-restart EasyTier if it drops**;
- Drop page cache;
- Write a resource snapshot to `/var/log/optimize.log`.

Cron entry:

```
0 * * * * /root/optimize.sh >/dev/null 2>&1
```

---

## EasyTier Deployment

Download the official static binary (musl-compatible, x86_64), verify its SHA256, and install to `/usr/local/bin`:

```sh
curl -fsSL -o easytier.zip \
  https://github.com/EasyTier/EasyTier/releases/download/v2.6.4/easytier-linux-x86_64-v2.6.4.zip
# SHA256: 61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6
python3 -c "import zipfile; zipfile.ZipFile('/tmp/easytier.zip').extractall('/tmp/et-pkg')"
install -m 755 /tmp/et-pkg/easytier-linux-x86_64/easytier-* /usr/local/bin/
```

See [`easytier-config.toml.example`](easytier-config.toml.example) for the config template (sanitized). See [`easytier-openrc`](easytier-openrc) for the OpenRC service file, then enable at boot:

```sh
rc-update add easytier default
rc-service easytier start
```

Verify:

```sh
easytier-cli node    # show local virtual IP / hostname
easytier-cli peer    # show peers and latency
```

---

## Test Lite Compact Toolkit

`test-lite/` is a compact benchmark toolkit written for the **TierHive 128MB NAT VPS**: pure busybox, no installs. It covers speed test, streaming accessibility, IP quality, route tracing and local benchmarks. Every network call is a read-only GET, with no POST, paste, or telemetry — the report is written locally only. It writes a Markdown report when the test finishes and cleans up its own temporary files. Works on Alpine 3.23.8 / 3.24.4 with ~2–4 MB extra RAM.

```sh
sh test-lite/test-lite.sh             # run all checks, write /root/test-lite-report.md
sh test-lite/test-lite.sh net         # speed + unlock + IP + route only
```

See [`test-lite/README.md`](test-lite/README.md).

---

## Webhook Debugging: webhook-tester

When you need to receive/debug webhooks (GitHub, GitLab, callbacks) on a 128MB box, use [`webhook-tester`](https://github.com/tarampampam/webhook-tester): it generates random URLs to capture HTTP requests, lets you inspect them in a built-in WebUI in real time, and customize the response code/headers/body/delay — a self-hosted alternative to `webhook.site`.

It is a single Go binary with an embedded React WebUI and no external dependencies: ~18 MB binary and ~12 MB runtime RSS — a good fit for long-running on a 128MB box.

**Install & run** (v2.3.0, official static binary, SHA256 verified):

```sh
curl -fsSL -o webhook-tester \
  https://github.com/tarampampam/webhook-tester/releases/download/v2.3.0/webhook-tester-linux-amd64
chmod +x webhook-tester
install -m 755 webhook-tester /usr/local/bin/webhook-tester
```

OpenRC service: [`webhook-tester-openrc`](webhook-tester-openrc), listening on `8081` by default:

```sh
rc-update add webhook-tester default
rc-service webhook-tester start
```

Access the WebUI over the EasyTier private network: `http://10.126.126.x:8081`. **Configured with `fs` persistent storage** (data under `/var/lib/webhook-tester`, captured requests survive restarts); the service file passes `--storage-driver fs --fs-storage-dir /var/lib/webhook-tester`, and that directory must exist beforehand. The default `memory` driver loses data on restart and is not used here.

---

## Files

| File | Purpose |
|---|---|
| `README.md` | This document |
| `optimize.sh` | Daily maintenance script (hourly) |
| `blacklist-unnecessary.conf` | Kernel module blacklist |
| `easytier-config.toml.example` | EasyTier config template (sanitized) |
| `easytier-openrc` | EasyTier OpenRC service definition |
| `webhook-tester-openrc` | webhook-tester OpenRC service definition (port 8081) |
| `test-lite/` | Compact benchmark toolkit for 128MB Alpine (see its README) |

---

## Quick Reproduce

```sh
# 1) Kernel layer: install blacklist, edit boot params, comment IPv6 sysctls, rebuild initramfs
cp blacklist-unnecessary.conf /etc/modprobe.d/
sed -i 's/audit=0 nowatchdog/ipv6.disable=1 audit=0 nowatchdog/' /boot/extlinux.conf
mkinitfs

# 2) Package cleanup (see "Stage 2" commands)

# 3) Install and configure EasyTier (see above)

# 4) Deploy the maintenance script and cron job
install -m 755 optimize.sh /root/optimize.sh
(crontab -l; echo "0 * * * * /root/optimize.sh >/dev/null 2>&1") | crontab -

# 5) Reboot for kernel parameters to take effect
reboot
```

After reboot, verify with `easytier-cli node` and `free -m`.

---

## Benchmarks

**Connection latency** (local machine → Japan box):

| Method | Full SSH login + command |
|---|---:|
| EasyTier private `10.126.126.5:22` | **~1.13 s** |
| Proxy → public `4678` | ~2.08 s |

**Server bandwidth** (Tokyo node):

- Download: ~9–11 Mbps (Cloudflare / Hetzner measured)
- To Cloudflare: ~8 ms; to China DNS: ~83 ms

**Network**: all 6 peers visible, P2P direct preferred, 60–400 ms latency depending on location.

---

## Caveats

1. **Version differences**: some TierHive machines ship with Alpine 3.23.8, others with 3.24.4; this works on both.
2. **Do not disable zram**: 128MB machines rely on zram for `apk` operations; disabling it causes upgrade failures or even a broken system.
3. **Unique instance_id**: do not reuse the same `instance_id` across machines; use a fresh UUID on conflict.
4. **SSH service**: keep OpenSSH rather than Dropbear to avoid losing access in a proxied environment.

---

## License

MIT
