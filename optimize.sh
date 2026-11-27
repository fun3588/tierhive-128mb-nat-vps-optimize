#!/bin/sh
# /root/optimize.sh - Alpine 小内存 VPS 日常优化维护 (幂等, 每小时定时运行)
# 基于 TierHive "Minimising Alpine" 指南, 针对本机 (zram + EasyTier) 调整
# 部署: install -m 755 optimize.sh /root/optimize.sh
# cron:  0 * * * * /root/optimize.sh >/dev/null 2>&1

LOG=/var/log/optimize.log
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

log "===== 开始日常优化 ====="

# 1. 清理 apk 缓存 (下载索引/包缓存, 可安全删除)
rm -rf /var/cache/apk/* 2>/dev/null
log "apk 缓存已清理"

# 2. 清理 /tmp 中的陈旧安装/临时文件
find /tmp -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null
find /tmp -maxdepth 1 -type d -mtime +2 -exec rm -rf {} + 2>/dev/null
log "/tmp 陈旧文件已清理"

# 3. 日志轮转 (easytier + 系统日志)
command -v logrotate >/dev/null 2>&1 && logrotate /etc/logrotate.conf >/dev/null 2>&1
log "日志轮转已执行"

# 4. 块设备预读 128KB (虚拟磁盘默认值偏大, 浪费内存)
for d in /sys/block/vd*/queue/read_ahead_kb; do
    [ -f "$d" ] && echo 128 > "$d" 2>/dev/null
done
log "readahead 已设为 128KB"

# 5. sysctl 微调 (幂等: 每次重新应用配置文件)
sysctl -p /etc/sysctl.conf >/dev/null 2>&1
for f in /etc/sysctl.d/*.conf; do
    sysctl -p "$f" >/dev/null 2>&1
done
log "sysctl 已应用"

# 6. zram 检查: 若掉线则重新启用 (保证 apk 操作有 swap 支撑)
if ! grep -q '/dev/zram0' /proc/swaps; then
    /etc/local.d/zram.start >/dev/null 2>&1 && log "zram 掉线, 已重新启用" || log "警告: zram 恢复失败"
else
    log "zram 正常"
fi

# 7. EasyTier 服务健康检查: 掉线则拉起
if ! rc-service easytier status >/dev/null 2>&1; then
    rc-service easytier restart >/dev/null 2>&1 && log "EasyTier 掉线, 已重启" || log "警告: EasyTier 重启失败"
else
    log "EasyTier 运行正常"
fi

# 8. 回收页面缓存 (不影响运行)
sync
echo 1 > /proc/sys/vm/drop_caches 2>/dev/null
log "已回收页面缓存"

# 9. 资源快照 (便于观察趋势)
log "资源: $(free -m | awk '/Mem:/{printf "mem used=%sM free=%sM cache=%sM", $3,$4,$6}') \
$(df -h / | awk 'NR==2{printf "disk used=%s avail=%s", $3,$4}') \
模块数=$(cat /proc/modules | wc -l)"

log "===== 完成 ====="
