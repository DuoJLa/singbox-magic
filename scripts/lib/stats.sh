#!/usr/bin/env bash
# stats.sh —— 流量统计（v2ray_api + grpcurl，reset=false 差值累计）、到期/超额检测
set -u
. /opt/sb-mgr/scripts/lib/common.sh

# 单实例锁（防并发，Opus S4）
stats_lock() {
  local lock=/run/sb-stats.lock
  if [ -f "$lock" ] && kill -0 "$(cat "$lock")" 2>/dev/null; then
    return 1
  fi
  echo $$ > "$lock"
  trap 'rm -f /run/sb-stats.lock' EXIT INT TERM
  return 0
}

# 拉取所有用户计数器（grpcurl JSON）
fetch_counters() { # → stdout: {"用户名":{"up":n,"down":n}}
  . "$SB_ETC/config.env" 2>/dev/null
  local port=${SB_API_PORT:-15490} token=${SB_API_TOKEN:-}
  [ -x "$SB_GRPCURL" ] || return 1
  local auth=()
  [ -n "$token" ] && auth=(-H "authorization: Bearer $token")
  "$SB_GRPCURL" -plaintext -max-time 10 "${auth[@]}" \
    -d '{"pattern":"","reset":false}' \
    "127.0.0.1:${port}" v2ray.core.app.stats.command.StatsService/QueryStats 2>/dev/null
}

# 主任务：差值累计 + 重置 + 到期/超额检测
run_stats() {
  sb_init_data
  . "$SB_ETC/config.env" 2>/dev/null
  [ "${SB_STATS_ENABLED:-0}" = "1" ] || exit 0
  stats_lock || exit 0
  [ -x "$SB_GRPCURL" ] || exit 0
  pgrep -x sing-box >/dev/null 2>&1 || exit 0

  local raw
  raw=$(fetch_counters) || exit 0
  [ -z "$raw" ] && exit 0

  # 解析 user>>>name>>>traffic>>>uplink/downlink
  local now=$(date +%s) changed=0
  local uname up down last_u last_d du dd
  _sb_tmp=$(mktemp)
  jq -r '.stat as $s |
      [$s[] | .name | sub("^user>>>";"") | sub(">>>traffic>>>(up|down)link$";"")] | unique | .[] as $u |
      [$u,
       ([$s[] | select(.name == "user>>>\($u)>>>traffic>>>uplink") | .value // 0][0] // 0),
       ([$s[] | select(.name == "user>>>\($u)>>>traffic>>>downlink") | .value // 0][0] // 0)] | @tsv' <<<"$raw" > "$_sb_tmp" 2>/dev/null
  while IFS=$'\t' read -r uname up down; do
    [ -z "$uname" ] && continue
    # 从 state.json 取上次计数
    last_u=$(jq -r ".counters[\"$uname\"].up // 0" "$SB_STATE" 2>/dev/null)
    last_d=$(jq -r ".counters[\"$uname\"].down // 0" "$SB_STATE" 2>/dev/null)
    du=$((up - last_u)); dd=$((down - last_d))
    [ "$du" -lt 0 ] && du=$up   # 核心重启后计数回落，全额记为增量
    [ "$dd" -lt 0 ] && dd=$down
    if [ "$du" -gt 0 ] || [ "$dd" -gt 0 ]; then
      jq --arg n "$uname" --argjson up "$up" --argjson down "$down" \
         '.counters[$n] = {up:$up, down:$down}' "$SB_STATE" 2>/dev/null \
        | sdb_write "$SB_STATE"
    fi
    if [ "$du" -gt 0 ] || [ "$dd" -gt 0 ]; then
      jq --arg n "$uname" --argjson t "$((du + dd))" \
         'map(if .name==$n then .used_bytes += $t else . end)' "$SB_USERS" \
        | sdb_write "$SB_USERS"
    fi
  done < "$_sb_tmp"
  rm -f "$_sb_tmp"

  # ===== 月度重置（自然月）=====
  local today_d=$(date +%-d) ym=$(date +%Y-%m) u
  _sb_tmp=$(mktemp)
  jq -c '.[]' "$SB_USERS" > "$_sb_tmp" 2>/dev/null
  while IFS= read -r u; do
    local name=$(jq -r '.name' <<<"$u") rd=$(jq -r '.reset_day' <<<"$u") last_reset=$(jq -r '.last_reset // ""' <<<"$u")
    if [ "$today_d" -ge "$rd" ] && [ "$last_reset" != "$ym" ]; then
      jq --arg n "$name" --arg ym "$ym" 'map(if .name==$n then .used_bytes=0 | .last_reset=$ym else . end)' "$SB_USERS" | sdb_write "$SB_USERS"
      changed=1
      sb_log "traffic reset: $name ($ym)"
    fi
  done < "$_sb_tmp"
  rm -f "$_sb_tmp"

  # ===== 到期/超额 → 重渲染 =====
  local need_reload=0
  _sb_tmp=$(mktemp)
  jq -c '.[]' "$SB_USERS" > "$_sb_tmp" 2>/dev/null
  while IFS= read -r u; do
    local active_now=1
    user_active "$u" || active_now=0
    local was=$(jq -r --arg n "$(jq -r .name <<<"$u")" '.active_users // [] | index($n) != null' "$SB_STATE")
    if [ "$active_now" = 1 ] && [ "$was" = false ]; then
      need_reload=1
      jq --arg n "$(jq -r .name <<<"$u")" '.active_users = ((.active_users // []) + [$n] | unique)' "$SB_STATE" | sdb_write "$SB_STATE"
    elif [ "$active_now" = 0 ] && [ "$was" = true ]; then
      need_reload=1
      jq --arg n "$(jq -r .name <<<"$u")" 'del(.active_users[] | select(. == $n))' "$SB_STATE" | sdb_write "$SB_STATE"
      sb_log "user deactivated: $(jq -r .name <<<"$u")"
    elif [ "$was" = false ] && [ "$active_now" = 0 ]; then
      # 首次记录
      :
    fi
  done < "$_sb_tmp"
  rm -f "$_sb_tmp"

  # 首次运行时初始化 active_users
  if ! jq -e '.active_users' "$SB_STATE" >/dev/null 2>&1; then
    local init='[]'
    _sb_tmp=$(mktemp)
    jq -c '.[]' "$SB_USERS" > "$_sb_tmp" 2>/dev/null
    while IFS= read -r u; do
      user_active "$u" && init=$(jq --arg n "$(jq -r .name <<<"$u")" '. + [$n]' <<<"$init")
    done < "$_sb_tmp"
    rm -f "$_sb_tmp"
    jq --argjson a "$init" '.active_users = $a' "$SB_STATE" | sdb_write "$SB_STATE"
  fi

  if [ "$need_reload" = 1 ]; then
    sb_log "user status changed, re-rendering config"
    apply_config >/dev/null 2>&1
  fi
}
