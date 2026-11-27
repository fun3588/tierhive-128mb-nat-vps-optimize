# Test Lite — Alpine 128MB 精简测评工具包

专为 **TierHive 128MB NAT VPS** 编写的精简测评工具：保留测速、流媒体解锁、IP 质量、路由追踪和本地性能测试，所有联网请求只读、结果不上传，并且不安装任何依赖。

- 适用系统：Alpine Linux **3.23.8 / 3.24.4**（busybox ash，无 bash / python）
- 依赖：仅 busybox 自带命令（`awk` / `dd` / `df` / `grep` / `sed` / `find` / `mktemp` / `wget` / `traceroute`）
- 资源：单文件约 13KB；运行时额外内存约 2–4 MB；磁盘测试临时文件 4–8 MB
- 结果：**只生成本机 Markdown 报告，永不上传**（无 POST、无 paste 服务、无遥测）
- 清理：不安装软件包；测试临时文件跑完即删，退出时清理过期临时目录

## 命令

```sh
sh test-lite.sh                  # 默认 all：系统信息 + 本地性能 + 四项网络测试 + 报告
sh test-lite.sh info             # 仅系统信息
sh test-lite.sh cpu              # 仅 CPU
sh test-lite.sh mem              # 仅内存（约 2MB 工作集，不会 OOM）
sh test-lite.sh disk             # 仅磁盘（写 8MB，测完即删）
sh test-lite.sh net              # 测速 + 解锁 + IP 质量 + 路由
sh test-lite.sh speed            # 仅下载测速
sh test-lite.sh unlock           # 仅流媒体可访问性
sh test-lite.sh ip               # 仅 IP 归属 / 质量
sh test-lite.sh route            # 仅路由追踪
sh test-lite.sh clean            # 清理遗留的 /tmp/test-lite.*
sh test-lite.sh all -o /root/report.md
```

默认报告写到 `/root/test-lite-report.md`（不可写时退到 `/tmp/test-lite-report.md`），可用 `-o` 改路径。

## 网络测试

| 类别 | 实现方式 | 边界 |
|---|---|---|
| 测速 | `wget` 下载 Cloudflare 1MB 文件到 `/dev/null`，按 `/proc/uptime` 计时 | 只测下载；不上传结果，也不做上行带宽测试 |
| 流媒体解锁 | 对 Netflix / Disney+ / HBO Max / YouTube / TikTok 请求首页，读 HTTP 状态码 | 仅判断可访问/受限，不做完整地域内容比对 |
| IP 质量 | `api4.ipify.org` 取公网 IPv4，`api6.ipify.org` 取公网 IPv6，`ipapi.co/json/` 取归属地和 ASN/组织 | 无 IPv6 时显示“无 / 不可达”；不含付费风控评分和 DNSBL 批量查询 |
| 路由追踪 | `ip route` 本地路由表 + `traceroute -n -q 1 -m 8 -w 1` 到 `1.1.1.1` | 上游过滤 ICMP/UDP 时可能无输出 |

自定义目标：

```sh
SPEED_URL='https://example.com/1mb.bin' SPEED_BYTES=1048576 \
TRACE_TARGET='1.1.1.1' sh test-lite.sh net
```

## 安全边界

- 所有联网请求都是只读 GET；不会把本机报告、CPU/内存/磁盘结果或任何本地数据提交到远端。
- DNS 解析由系统解析器完成，本工具不改写 `/etc/resolv.conf`。
- 磁盘测试只在自身临时目录写文件，剩余空间不足时自动降到 4MB。
- `clean` 只匹配 `/tmp/test-lite.*`，不会碰其他文件，也不会动 apk 包数据库。

---

# Test Lite — compact benchmark toolkit for 128MB Alpine

A compact benchmark toolkit written for the **TierHive 128MB NAT VPS**: keeps speed test, streaming accessibility, IP quality, route tracing and local benchmarks. Every network call is read-only and results are never uploaded; no packages are installed. Alpine 3.23.8 / 3.24.4, busybox only, ~2–4 MB extra RAM.

Report: `/root/test-lite-report.md` (or `-o PATH`). Commands: `all`, `info`, `cpu`, `mem`, `disk`, `net`, `speed`, `unlock`, `ip`, `route`, `clean`. Network checks are read-only GETs; the report stays on the local machine.
