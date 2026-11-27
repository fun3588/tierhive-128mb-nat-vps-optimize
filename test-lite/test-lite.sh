#!/bin/sh
# test-lite.sh - "融合怪" ECS 测评的 Alpine 128MB 精简版
# 来源思路: github.com/oneclickvirt/ecs
# 适配: Alpine Linux 3.23.8 / 3.24.4 (busybox ash, 无 bash/python)
# 原则: 零安装 / 保留测速+解锁+IP质量+路由 / 结果永不上传 / 测完即清理
# 用法: sh test-lite.sh [all|info|cpu|mem|disk|net|speed|unlock|ip|route|clean] [-o 报告路径]

set -u

VERSION='1.0.0'
CMD='all'
OUT=''
TMP=''
REPORT=''
CLEAN_NOTE='未产生'
SPEED_URL=${SPEED_URL:-'https://speed.cloudflare.com/__down?bytes=1048576'}
SPEED_BYTES=${SPEED_BYTES:-1048576}
TRACE_TARGET=${TRACE_TARGET:-'1.1.1.1'}

die() { printf '%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
test-lite 1.0.0 - Alpine 128MB VPS 精简测评工具

用法: sh test-lite.sh [命令] [-o 报告路径]

命令:
  all      全部测试（系统信息 + 本地性能 + 测速 + 解锁 + IP 质量 + 路由）
  info     仅系统信息
  cpu      仅 CPU 测试
  mem      仅内存测试（约 2MB 工作集，不会 OOM）
  disk     仅磁盘测试（写 8MB，测完立即删除）
  net      全部网络测试（测速 + 解锁 + IP 质量 + 路由）
  speed    仅下载测速
  unlock   仅流媒体可访问性检查
  ip       仅 IP 质量/归属查询
  route    仅路由追踪
  clean    清理遗留的 /tmp/test-lite.* 临时目录
  help     显示本帮助

选项:
  -o, --out FILE   指定报告路径（默认 /root/test-lite-report.md）

环境变量:
  SPEED_URL      测速下载地址（默认 Cloudflare 1MB 文件）
  SPEED_BYTES    测速文件字节数（默认 1048576）
  TRACE_TARGET   路由追踪目标（默认 1.1.1.1）

说明: 不安装任何软件包；联网项目只读取公开接口，测试结果永不上传。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--out)
            [ "$#" -ge 2 ] || die '-o 需要一个文件路径'
            OUT=$2; shift 2 ;;
        -h|--help|help) CMD=help; shift ;;
        info|cpu|mem|disk|all|net|speed|unlock|ip|route|clean) CMD=$1; shift ;;
        *) die "未知参数: $1 (用 help 查看用法)" ;;
    esac
done

[ "$CMD" = help ] && { usage; exit 0; }

# ---------------------------------------------------------------- 临时目录与清理

TMP=$(mktemp -d /tmp/test-lite.XXXXXX 2>/dev/null) || {
    TMP="/tmp/test-lite.$$"
    mkdir -p "$TMP" 2>/dev/null || TMP=''
}

clean_old() {
    [ -d /tmp ] || return 0
    for d in $(find /tmp -maxdepth 1 -name 'test-lite.*' -mtime +1 2>/dev/null); do
        case "$d" in
            /tmp/test-lite.*) rm -rf "$d" 2>/dev/null && printf '已清理旧临时目录: %s\n' "$d" ;;
        esac
    done
}

cleanup() {
    [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null
    clean_old >/dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$CMD" = clean ]; then
    printf '清理 test-lite 遗留文件...\n'
    n=$(clean_old | wc -l)
    printf '完成，清理条目: %s\n' "$n"
    exit 0
fi

# ---------------------------------------------------------------- 报告与目标路径

[ -n "$TMP" ] || die '无法创建临时目录 /tmp/test-lite.XXXXXX'
REPORT="$TMP/report.md"

if [ -z "$OUT" ]; then
    if [ -w /root ]; then OUT='/root/test-lite-report.md'
    else OUT='/tmp/test-lite-report.md'; fi
fi
mkdir -p "$(dirname "$OUT")" 2>/dev/null || die "无法创建报告目录: $(dirname "$OUT")"

p() { printf '%s\n' "$@" >> "$REPORT"; }

p '# Test Lite 测评报告'
p ''
p "- 生成时间: $(date '+%F %T' 2>/dev/null || date)"
p "- 工具版本: test-lite ${VERSION}"
p '- 运行环境: Alpine 3.23.8 / 3.24.4 (128MB NAT VPS)'
p '- 网络行为: 只读公开接口做测速/解锁/IP/路由检测；结果永不上传。'
p ''

# ---------------------------------------------------------------- 通用工具

now() { awk '{print $1+0}' /proc/uptime 2>/dev/null || echo 0; }

uptime_text() {
    awk '{s=$1+0; d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); printf "%dd %dh %dm",d,h,m}' \
        /proc/uptime 2>/dev/null || echo '未知'
}

os_name() {
    if [ -r /etc/alpine-release ]; then printf 'Alpine Linux %s' "$(cat /etc/alpine-release)"
    elif [ -r /etc/os-release ]; then
        grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"'
    else echo '未知'; fi
}

cpu_model() {
    awk -F: '/^model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null
}

ip_list() {
    result=''
    if command -v ip >/dev/null 2>&1; then
        for addr in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}'); do
            [ -z "$result" ] && result=$addr || result="$result, $addr"
        done
    fi
    [ -z "$result" ] && result=$(hostname -i 2>/dev/null || echo '未知')
    printf '%s' "$result"
}

fetch() { wget -q -T 10 -O - "$1" 2>/dev/null; }

http_code() {
    url=$1
    tag=$2
    out="$TMP/http.$tag"
    hdr="$TMP/hdr.$tag"
    wget -S -T 8 -O "$out" "$url" 2>"$hdr" >/dev/null
    rc=$?
    code=$(awk '/HTTP\//{print $2; exit}' "$hdr" 2>/dev/null)
    rm -f "$out" "$hdr" 2>/dev/null
    if [ "$rc" -eq 0 ]; then printf '%s' "${code:-200}"
    else printf '%s' "${code:-000}"; fi
}

# ---------------------------------------------------------------- 系统信息

info_section() {
    p '## 系统信息'
    p ''
    p '| 项目 | 值 |'
    p '|---|---|'

    p "| 主机名 | $(hostname 2>/dev/null || echo 未知) |"
    p "| 系统 | $(os_name) |"
    p "| 内核 | $(uname -sr 2>/dev/null || echo 未知) |"
    p "| 架构 | $(uname -m 2>/dev/null || echo 未知) |"
    p "| 运行时间 | $(uptime_text) |"
    p "| 负载 | $(awk '{print $1" / "$2" / "$3}' /proc/loadavg 2>/dev/null || echo 未知) |"

    model=$(cpu_model)
    [ -z "$model" ] && model=$(awk -F: '/^Hardware/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null)
    [ -z "$model" ] && model='未知'
    cores=$(awk '/^processor/{n++} END{print n+0}' /proc/cpuinfo 2>/dev/null)
    p "| CPU | $model |"
    p "| CPU 核心 | ${cores:-未知} |"
    virt=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
    [ -z "$virt" ] && virt='未知'
    p "| 虚拟化 | $virt |"

    set -- $(awk '
        /^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
        /^MemFree:/{f=$2} /^Buffers:/{b=$2} /^Cached:/{c=$2}
        /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
        END{if(a=="")a=f+b+c; printf "%.0f %.0f %.0f %.0f",t/1024,a/1024,st/1024,(st-sf)/1024}
    ' /proc/meminfo 2>/dev/null)
    p "| 内存 | 总 ${1:-?} MB / 可用 ${2:-?} MB |"
    p "| Swap | 总 ${3:-?} MB / 已用 ${4:-?} MB |"
    zram=$(grep -c zram /proc/swaps 2>/dev/null || echo 0)
    p "| zram | $([ "$zram" -gt 0 ] 2>/dev/null && echo 已启用 || echo 未启用) |"
    p "| 磁盘 (根) | $(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)",$3,$2,$5}') |"
    p "| IPv4 (本地) | $(ip_list) |"

    pkgs=$(grep -c '^P:' /lib/apk/db/installed 2>/dev/null || echo '未知')
    mods=$(awk 'END{print NR+0}' /proc/modules 2>/dev/null)
    p "| 已安装包 | $pkgs |"
    p "| 已加载模块 | ${mods:-未知} |"
    if command -v easytier-cli >/dev/null 2>&1; then p '| EasyTier | 已安装 |'
    else p '| EasyTier | 未安装 |'; fi
    p ''
}

# ---------------------------------------------------------------- 本地性能测试

bench_section() {
    p '## 性能测试'
    p ''
    p '| 项目 | 结果 | 说明 |'
    p '|---|---:|---|'

    case "$CMD" in
        all|cpu)
            score=$(awk '
                function up(){ if ((getline l < "/proc/uptime")>0){split(l,a," ");close("/proc/uptime");return a[1]+0} return 0 }
                BEGIN{ s=up(); if(s==0) exit; i=0
                    while(1){ i++
                        if(i%65536==0){ t=up(); if(t-s>=2) break }
                    }
                    printf "%d", i/2
                }' 2>/dev/null)
            if [ -n "$score" ] && [ "$score" -gt 0 ] 2>/dev/null; then
                p "| CPU 整数循环 | 约 ${score} it/s | busybox awk，2 秒采样 |"
            else p '| CPU | 跳过 | 缺少 /proc/uptime |'; fi ;;
    esac

    case "$CMD" in
        all|mem)
            score=$(awk '
                function up(){ if ((getline l < "/proc/uptime")>0){split(l,a," ");close("/proc/uptime");return a[1]+0} return 0 }
                BEGIN{ s=up(); if(s==0) exit
                    str="0123456789abcdef"; while(length(str)<2097152) str=str str
                    str=substr(str,1,2097152); n=0
                    while(1){ for(k=0;k<64;k++){
                            j=(n*61+k*37)%2000003
                            total+=length(substr(str,j,4096))
                        }
                        n++
                        if(n%64==0){ t=up(); if(t-s>=2) break }
                    }
                    printf "%.1f", (n*64*4096)/(t-s)/1048576
                }' 2>/dev/null)
            if [ -n "$score" ] && [ "$score" != 0 ] 2>/dev/null; then
                p "| 内存拷贝 | 约 ${score} MB/s | 2MB 工作集，循环取子串 2 秒 |"
            else p '| 内存 | 跳过 | 缺少 /proc/uptime |'; fi ;;
    esac

    case "$CMD" in
        all|disk)
            file="$TMP/disktest.bin"
            free_kb=$(df -k "$TMP" 2>/dev/null | awk 'NR==2{print $4}')
            count=128
            if [ -n "$free_kb" ] && [ "$free_kb" -lt 65536 ] 2>/dev/null; then count=64; fi
            s=$(now)
            if dd if=/dev/zero of="$file" bs=64k count="$count" 2>/dev/null; then
                sync
                m=$(now)
                dd if="$file" of=/dev/null bs=64k 2>/dev/null
                e=$(now)
                result=$(awk -v s="$s" -v m="$m" -v e="$e" -v c="$count" \
                    'BEGIN{mb=c*64/1024; wd=m-s; rd=e-m; if(wd<=0)wd=0.001; if(rd<=0)rd=0.001; printf "%.1f %.1f", mb/wd, mb/rd}')
                set -- $result
                p "| 磁盘写入 | 约 ${1:-?} MB/s | dd 顺序写 ${count} 个 64KB 块 |"
                p "| 磁盘读取 | 约 ${2:-?} MB/s | 同一文件顺序读，受页缓存影响 |"
                rm -f "$file" 2>/dev/null
                CLEAN_NOTE="已删除 $file（$(awk -v c="$count" 'BEGIN{printf "%d",c*64/1024}')MB 测试文件）"
            else p '| 磁盘 | 跳过 | dd 写入失败或空间不足 |'; fi ;;
    esac

    case "$CMD" in
        all|net|speed) speed_test ;;
    esac
    p ''
}

# ---------------------------------------------------------------- 网络测试

speed_test() {
    if ! command -v wget >/dev/null 2>&1; then
        p '| 下载测速 | 跳过 | 未找到 busybox wget |'; return
    fi
    s=$(now)
    [ "$s" = 0 ] && { p '| 下载测速 | 跳过 | 缺少 /proc/uptime |'; return; }
    if wget -q -T 15 -O /dev/null "$SPEED_URL" 2>/dev/null; then
        e=$(now)
        speed=$(awk -v s="$s" -v e="$e" -v b="$SPEED_BYTES" \
            'BEGIN{d=e-s; if(d<=0)d=0.001; printf "%.2f", b/d/1048576}')
        p "| 下载测速 | 约 ${speed} MB/s | 下载 ${SPEED_BYTES} 字节到 /dev/null，不上传结果 |"
    else
        p '| 下载测速 | 跳过 | 目标不可达或超时 |'
    fi
}

ip_quality() {
    public_ip=$(fetch 'https://api4.ipify.org' 2>/dev/null)
    [ -z "$public_ip" ] && public_ip=$(fetch 'https://api.ipify.org' 2>/dev/null)
    [ -z "$public_ip" ] && public_ip='未知'
    p "| 公网 IPv4 | $public_ip | 仅本地显示，未提交到任何结果服务 |"

    public_ip6=$(wget -q -T 6 -O - 'https://api6.ipify.org' 2>/dev/null)
    case "$public_ip6" in
        *:*) ;;
        *) public_ip6='无 / 不可达' ;;
    esac
    p "| 公网 IPv6 | $public_ip6 | api6.ipify.org；无 IPv6 时超时跳过 |"

    geo=$(fetch 'https://ipapi.co/json/' 2>/dev/null)
    country=$(printf '%s' "$geo" | sed -n 's/.*"country_name": *"\([^"]*\)".*/\1/p' 2>/dev/null)
    city=$(printf '%s' "$geo" | sed -n 's/.*"city": *"\([^"]*\)".*/\1/p' 2>/dev/null)
    org=$(printf '%s' "$geo" | sed -n 's/.*"org": *"\([^"]*\)".*/\1/p' 2>/dev/null)
    asn=$(printf '%s' "$geo" | sed -n 's/.*"asn": *"\([^"]*\)".*/\1/p' 2>/dev/null)
    [ -z "$country" ] && country='未知'
    [ -z "$city" ] && city='未知'
    [ -z "$org" ] && org='未知'
    p "| 归属地 | ${country} / ${city} | ipapi.co 公开接口 |"
    p "| AS / 组织 | ${asn:-未知} ${org} | 仅用于判断 IP 质量 |"
}

unlock_check() {
    name=$1
    url=$2
    seq=$3
    code=$(http_code "$url" "$seq")
    case "$code" in
        200) label='可访问' ;;
        301|302|303|307|308) label='跳转后可访问' ;;
        403|451|404) label='受限/区域拦截' ;;
        000) label='不可达' ;;
        *) label="HTTP $code" ;;
    esac
    p "| $name | $label | HTTP $code，仅状态码判断 |"
}

unlock_test() {
    unlock_check 'Netflix'  'https://www.netflix.com/'     1
    unlock_check 'Disney+'  'https://www.disneyplus.com/'  2
    unlock_check 'HBO Max'  'https://www.max.com/'         3
    unlock_check 'YouTube'  'https://www.youtube.com/'     4
    unlock_check 'TikTok'   'https://www.tiktok.com/'      5
    p ''
    p '> 说明：以上只检查 HTTP 可访问性，不等于完整流媒体解锁检测（无解码/地域内容比对）。'
}

route_test() {
    if command -v ip >/dev/null 2>&1; then
        routes=$(ip route 2>/dev/null | head -10)
        p ''
        p '### 本地路由表'
        p ''
        p '```text'
        [ -n "$routes" ] && p "$routes" || p '（无输出）'
        p '```'
    fi

    p ''
    p "### 路由追踪 / 连通性 -> ${TRACE_TARGET}（traceroute 最多 8 跳，1 次探测）"
    p ''
    if command -v traceroute >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            tr=$(timeout 30 traceroute -n -q 1 -m 8 -w 1 "$TRACE_TARGET" 2>/dev/null)
        else
            tr=$(traceroute -n -q 1 -m 8 -w 1 "$TRACE_TARGET" 2>/dev/null)
        fi
        p '```text'
        [ -n "$tr" ] && p "$tr" || p '（无输出，可能被上游过滤 ICMP/UDP）'
        p '```'
    elif command -v ping >/dev/null 2>&1; then
        p '```text'
        p 'traceroute 不可用，改用 ping 连通性检测:'
        ping_out=$(ping -c 2 -W 1 "$TRACE_TARGET" 2>/dev/null \
            | grep -E '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' 2>/dev/null | tail -4)
        [ -n "$ping_out" ] && p "$ping_out" || p '（无输出，ICMP 可能被过滤）'
        p '```'
    else
        p '> traceroute / ping 均不可用，已跳过（本工具不会自动安装）。'
    fi
}

net_section() {
    p '## 网络测试'
    p ''
    p '| 项目 | 结果 | 说明 |'
    p '|---|---|---|'

    case "$CMD" in
        all|net|ip) ip_quality ;;
    esac
    case "$CMD" in
        all|net|unlock) unlock_test ;;
    esac
    case "$CMD" in
        all|net|route) route_test ;;
    esac
    p ''
}

# ---------------------------------------------------------------- 组装与输出

case "$CMD" in
    all|info) info_section ;;
esac

case "$CMD" in
    all|cpu|mem|disk) bench_section ;;
    speed)
        p '## 性能测试'
        p ''
        p '| 项目 | 结果 | 说明 |'
        p '|---|---:|---|'
        speed_test
        p '' ;;
esac

case "$CMD" in
    all|net|ip|unlock|route) net_section ;;
esac

p '## 清理记录'
p ''
p '- 安装软件包: 0（全程不执行 apk add，不下载/安装二进制）'
p "- 测试临时文件: $CLEAN_NOTE"
p "- 临时目录: $TMP（脚本退出时自动删除）"
p '- 结果上传: 无（测速/解锁/IP/路由均为只读请求，报告只写本机）'
p '- 旧临时目录: 超过 1 天的 /tmp/test-lite.* 会在退出时清理'
p ''

if mv -f "$REPORT" "$OUT" 2>/dev/null; then
    printf '报告已生成: %s\n' "$OUT"
else
    printf '警告: 无法写入 %s，报告内容如下:\n' "$OUT" >&2
    cat "$REPORT"
    exit 1
fi
