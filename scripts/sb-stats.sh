#!/usr/bin/env bash
# sb-stats.sh —— 定时统计任务执行体（systemd timer / cron 调用）
set -u
. /opt/sb-mgr/scripts/lib/common.sh
. /opt/sb-mgr/scripts/lib/genconfig.sh
. /opt/sb-mgr/scripts/lib/stats.sh
run_stats
