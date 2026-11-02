#!/usr/bin/env bash
# sb-mgr 公共库：路径、JSON 读写、工具函数
# shellcheck shell=bash
set -u

SB_ETC=/etc/sing-box-mgr
SB_DATA=$SB_ETC/data
SB_USERS=$SB_DATA/users.json
SB_INBOUNDS=$SB_DATA/inbounds.json
SB_OUTBOUNDS=$SB_DATA/outbounds.json
SB_STATE=$SB_DATA/state.json
SB_CONFIG=$SB_ETC/config.json
SB_CONFIG_BAK=$SB_ETC/config.json.bak
SB_SUBS_DIR=$SB_ETC/subs
SB_LOG=/var/log/sb-mgr.log
SB_SCRIPTS=/opt/sb-mgr/scripts
SB_BIN=/usr/local/bin
SB_CORE=$SB_BIN/sing-box
SB_GRPCURL=$SB_BIN/bin/grpcurl
SB_VERSION="1.0.0"
SB_PLAN_VERSION=1   # 备份结构版本，恢复时校验/迁移

# ---------- 日志 ----------
sb_log() { echo "[$(date '+%F %T')] $*" >> "$SB_LOG"; }

# ---------- JSON 初始化/读取 ----------
sb_init_data() {
  mkdir -p "$SB_DATA" "$SB_SUBS_DIR" /var/log
  [ -f "$SB_USERS" ]     || echo '[]' > "$SB_USERS"
  [ -f "$SB_INBOUNDS" ]  || echo '[]' > "$SB_INBOUNDS"
  [ -f "$SB_OUTBOUNDS" ] || echo '[]' > "$SB_OUTBOUNDS"
  [ -f "$SB_STATE" ]     || echo '{}' > "$SB_STATE"
  touch "$SB_LOG"
}

# jq 读取: sdb_get <file> <filter>
sdb_get() { jq -r "$2" "$1" 2>/dev/null; }

# 原子写 JSON: echo/json 传入 stdin → sdb_write <file>
sdb_write() {
  local f=$1 tmp
  tmp=$(mktemp "${f}.XXXXXX") || return 1
  if cat > "$tmp" && jq empty "$tmp" 2>/dev/null; then
    cp "$f" "$f.bak" 2>/dev/null
    mv "$tmp" "$f"
    return 0
  fi
  rm -f "$tmp"; return 1
}

# ---------- ID 生成 ----------
sdb_next_id() { # <file>
  local max
  max=$(jq '[.[].id] | max // 0' "$1" 2>/dev/null)
  echo $((max + 1))
}

# ---------- 凭证生成 ----------
gen_uuid() { cat /proc/sys/kernel/random/uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
gen_pass() { openssl rand -base64 "$1" 2>/dev/null | tr -d '\n' | tr '+/' '-_'; }
# SS2022 密钥：n 字节原始 → 标准 base64（必须精确长度，不能 tr 字符集）
gen_ss2022_key() { openssl rand "$1" 2>/dev/null | base64 | tr -d '\n'; }
gen_short_id() { openssl rand -hex 4; }

# ---------- 人类可读 ----------
fmt_bytes() { # <bytes>
  local b=$1
  if   [ "$b" -ge $((1073741824 * 1024)) ]; then awk -v b="$b" 'BEGIN{printf "%.1fTB", b/1099511627776/1024}'
  elif [ "$b" -ge 1073741824 ]; then awk -v b="$b" 'BEGIN{printf "%.1fGB", b/1073741824}'
  elif [ "$b" -ge 1048576 ];    then awk -v b="$b" 'BEGIN{printf "%.1fMB", b/1048576}'
  elif [ "$b" -ge 1024 ];       then awk -v b="$b" 'BEGIN{printf "%.1fKB", b/1024}'
  else echo "${b}B"; fi
}
# 兼容 BusyBox base64（无 -w0）的编码聚合
b64_oneline() { base64 | tr -d '\n'; }

# ---------- 系统/服务探测 ----------
detect_os() {
  if [ -f /etc/debian_version ]; then echo debian
  elif [ -f /etc/alpine-release ]; then echo alpine
  elif command -v apt >/dev/null 2>&1; then echo debian
  elif command -v apk >/dev/null 2>&1; then echo alpine
  else echo other; fi
}
detect_init() {
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then echo systemd
  elif command -v rc-service >/dev/null 2>&1; then echo openrc
  else echo none; fi
}
svc_action() { # <start|stop|restart|status> [service]
  local act=$1 svc=${2:-sing-box}
  case "$(detect_init)" in
    systemd) systemctl "$act" "$svc" 2>/dev/null ;;
    openrc)  rc-service "$svc" "$act" 2>/dev/null ;;
    none)    [ "$act" = status ] && pgrep -x sing-box >/dev/null && echo running || echo stopped ;;
  esac
}
core_status() {
  if [ -x "$SB_CORE" ]; then
    if pgrep -x sing-box >/dev/null 2>&1; then
      echo "运行中 v$("$SB_CORE" version 2>/dev/null | head -1 | awk '{print $3}' | tr -d ',')"
    else
      echo "已停止 v$("$SB_CORE" version 2>/dev/null | head -1 | awk '{print $3}' | tr -d ',')"
    fi
  else echo "未安装"; fi
}

# ---------- 主机公网 IP ----------
get_public_ip() {
  curl -fs4m 5 https://api.ipify.org 2>/dev/null \
   || curl -fs4m 5 https://ifconfig.me 2>/dev/null \
   || echo "127.0.0.1"
}

# ---------- 流量/到期判定 ----------
user_remaining_days() { # <expiry yyyy-mm-dd>
  local e=$1
  [ -z "$e" ] && { echo "永久"; return; }
  local d=$(( ($(date -d "$e" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$e" +%s 2>/dev/null) - $(date +%s)) / 86400 ))
  if [ "$d" -lt 0 ]; then echo "已到期"; elif [ "$d" -eq 0 ]; then echo "今日到期"; else echo "${d}天"; fi
}
