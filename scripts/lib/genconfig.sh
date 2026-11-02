#!/usr/bin/env bash
# genconfig.sh —— 状态数据 → config.json 渲染器（唯一写 config 入口）
# 渲染 → sing-box check → 通过才 apply（restart），失败回滚 .bak
set -u
. /opt/sb-mgr/scripts/lib/common.sh

# 入站协议 → 渲染 sing-box inbound JSON 对象
# 参数：入站对象(JSON字符串) 已激活用户数组(JSON: [{name,...bindings字段}])
render_inbound() {
  local inb=$1 act_users=$2
  local id proto port listen name
  id=$(jq -r '.id' <<<"$inb"); proto=$(jq -r '.proto' <<<"$inb")
  port=$(jq -r '.port' <<<"$inb"); listen=$(jq -r '.listen // "0.0.0.0"' <<<"$inb")
  name="in-${id}"
  local users_json='[]'
  case $proto in
    vless-reality)
      users_json=$(jq -c '[.[] | {name: .name, uuid: .uuid, flow: "xtls-rprx-vision"}]' <<<"$act_users" 2>/dev/null || echo '[]')
      jq -nc --arg n "$name" --arg l "$listen" --argjson p "$port" \
         --arg sni "$(jq -r '.reality.sni' <<<"$inb")" \
         --arg dest "$(jq -r '.reality.dest' <<<"$inb")" \
         --arg pk "$(jq -r '.reality.private_key' <<<"$inb")" \
         --arg sid "$(jq -r '.reality.short_id' <<<"$inb")" \
         --argjson users "$users_json" \
        '{type:"vless", tag:$n, listen:$l, listen_port:$p,
          users:$users,
          tls:{enabled:true, server_name:$sni,
               reality:{enabled:true, handshake:{server:$dest, server_port:443},
                        private_key:$pk, short_id:[$sid]}}}'
      ;;
    vless-ws)
      users_json=$(jq -c '[.[] | {name:.name, uuid:.uuid}]' <<<"$act_users")
      jq -nc --arg n "$name" --arg l "$listen" --argjson p "$port" \
         --arg path "$(jq -r '.ws.path' <<<"$inb")" \
         --arg sni "$(jq -r '.tls.sni // ""' <<<"$inb")" \
         --arg cert "$(jq -r '.tls.cert // ""' <<<"$inb")" \
         --arg key "$(jq -r '.tls.key // ""' <<<"$inb")" \
         --argjson users "$users_json" \
        '{type:"vless", tag:$n, listen:$l, listen_port:$p, users:$users,
          transport:{type:"ws", path:$path},
          tls:({enabled:true}
               + (if $sni != "" then {server_name:$sni} else {} end)
               + (if $cert != "" then {certificate_path:$cert, key_path:$key} else {} end))}'
      ;;
    trojan-ws)
      users_json=$(jq -c '[.[] | {name:.name, password:.password}]' <<<"$act_users")
      jq -nc --arg n "$name" --arg l "$listen" --argjson p "$port" \
         --arg path "$(jq -r '.ws.path' <<<"$inb")" \
         --arg sni "$(jq -r '.tls.sni // ""' <<<"$inb")" \
         --arg cert "$(jq -r '.tls.cert // ""' <<<"$inb")" \
         --arg key "$(jq -r '.tls.key // ""' <<<"$inb")" \
         --argjson users "$users_json" \
        '{type:"trojan", tag:$n, listen:$l, listen_port:$p, users:$users,
          transport:{type:"ws", path:$path},
          tls:({enabled:true}
               + (if $sni != "" then {server_name:$sni} else {} end)
               + (if $cert != "" then {certificate_path:$cert, key_path:$key} else {} end))}'
      ;;
    vless-grpc)
      users_json=$(jq -c '[.[] | {name:.name, uuid:.uuid}]' <<<"$act_users")
      jq -nc --arg n "$name" --arg l "$listen" --argjson p "$port" \
         --arg sn "$(jq -r '.grpc.service_name' <<<"$inb")" \
         --arg sni "$(jq -r '.tls.sni // ""' <<<"$inb")" \
         --arg cert "$(jq -r '.tls.cert // ""' <<<"$inb")" \
         --arg key "$(jq -r '.tls.key // ""' <<<"$inb")" \
         --argjson users "$users_json" \
        '{type:"vless", tag:$n, listen:$l, listen_port:$p, users:$users,
          transport:{type:"grpc", service_name:$sn},
          tls:({enabled:true}
               + (if $sni != "" then {server_name:$sni} else {} end)
               + (if $cert != "" then {certificate_path:$cert, key_path:$key} else {} end))}'
      ;;
    anytls)
      users_json=$(jq -c '[.[] | {name:.name, password:.password}]' <<<"$act_users")
      jq -nc --arg n "$name" --arg l "$listen" --argjson p "$port" \
         --arg sni "$(jq -r '.tls.sni // ""' <<<"$inb")" \
         --arg cert "$(jq -r '.tls.cert // ""' <<<"$inb")" \
         --arg key "$(jq -r '.tls.key // ""' <<<"$inb")" \
         --argjson users "$users_json" \
        '{type:"anytls", tag:$n, listen:$l, listen_port:$p, users:$users,
          tls:({enabled:true}
               + (if $sni != "" then {server_name:$sni} else {} end)
               + (if $cert != "" then {certificate_path:$cert, key_path:$key} else {} end))}'
      ;;
    hysteria2)
      users_json=$(jq -c '[.[] | {name:.name, password:.password}]' <<<"$act_users")
      jq -nc --arg n "$name" --arg l "$listen" --argjson p "$port" \
         --arg cert "$(jq -r '.tls.cert // ""' <<<"$inb")" \
         --arg key "$(jq -r '.tls.key // ""' <<<"$inb")" \
         --argjson up "$(jq '.up_mbps // 0' <<<"$inb")" \
         --argjson down "$(jq '.down_mbps // 0' <<<"$inb")" \
         --argjson igcb "$(jq '.ignore_client_bandwidth // false' <<<"$inb")" \
         --argjson users "$users_json" \
        '{type:"hysteria2", tag:$n, listen:$l, listen_port:$p, users:$users,
          up_mbps:$up, down_mbps:$down, ignore_client_bandwidth:$igcb,
          tls:{enabled:true, certificate_path:$cert, key_path:$key}}'
      ;;
    tuic)
      users_json=$(jq -c '[.[] | {name:.name, uuid:.uuid, password:.password}]' <<<"$act_users")
      jq -nc --arg n "$name" --arg l "$listen" --argjson p "$port" \
         --arg cc "$(jq -r '.congestion_control // "bbr"' <<<"$inb")" \
         --arg cert "$(jq -r '.tls.cert // ""' <<<"$inb")" \
         --arg key "$(jq -r '.tls.key // ""' <<<"$inb")" \
         --argjson users "$users_json" \
        '{type:"tuic", tag:$n, listen:$l, listen_port:$p, users:$users,
          congestion_control:$cc,
          tls:{enabled:true, certificate_path:$cert, key_path:$key}}'
      ;;
    shadowsocks)
      # 2022 多用户：入站主密钥 + 每用户独立密钥（客户端密码 = 主密钥:用户密钥，仅用于链接）
      local mk=$(jq -r '.ss2022.server_key' <<<"$inb")
      users_json=$(jq -c '[.[] | {name:.name, password:.password}]' <<<"$act_users")
      jq -nc --arg n "$name" --arg l "$listen" --argjson p "$port" \
         --arg method "$(jq -r '.ss2022.method' <<<"$inb")" \
         --arg pw "$mk" \
         --argjson users "$users_json" \
        '{type:"shadowsocks", tag:$n, listen:$l, listen_port:$p,
          method:$method, password:$pw, users:$users}'
      ;;
    vless-tcp)
      users_json=$(jq -c '[.[] | {name:.name, uuid:.uuid}]' <<<"$act_users")
      jq -nc --arg n "$name" --arg l "$listen" --argjson p "$port" \
         --argjson users "$users_json" \
        '{type:"vless", tag:$n, listen:$l, listen_port:$p, users:$users}'
      ;;
    socks)
      users_json=$(jq -c '[.[] | {username:.socks_user, password:.socks_pass}]' <<<"$act_users")
      jq -nc --arg n "$name" --arg l "$listen" --argjson p "$port" \
         --argjson users "$users_json" \
        '{type:"socks", tag:$n, listen:$l, listen_port:$p, users:$users}'
      ;;
    *) echo 'null' ;;
  esac
}

# 判断用户是否激活（未到期 & 未超额）
user_active() { # <user对象JSON>
  local expiry quota used
  expiry=$(jq -r '.expiry // ""' <<<"$1")
  quota=$(jq -r '.quota_bytes // 0' <<<"$1")
  used=$(jq -r '.used_bytes // 0' <<<"$1")
  if [ -n "$expiry" ] && [ "$(date +%s)" -gt "$(date -d "$expiry" +%s 2>/dev/null || echo 0)" ] 2>/dev/null; then
    return 1
  fi
  [ "$quota" -gt 0 ] && [ "$used" -ge "$quota" ] && return 1
  return 0
}

# ===== 主渲染流程 =====
gen_config() {
  [ -x "$SB_CORE" ] || { echo "错误: sing-box 核心未安装，无法渲染"; return 1; }
  sb_init_data

  # 收集配置参数
  . "$SB_ETC/config.env" 2>/dev/null
  local api_port=${SB_API_PORT:-15490} api_token=${SB_API_TOKEN:-$(gen_uuid)}

  # 1. 收集入站 + 各入站激活用户
  local inbounds_json='[]'
  local stats_users='[]'
  _sb_tmp=$(mktemp)
  jq -c '.[]' "$SB_INBOUNDS" > "$_sb_tmp" 2>/dev/null
  while IFS= read -r inb; do
    local iid=$(jq -r '.id' <<<"$inb")
    # 找出绑定此入站且激活的用户
    local act
    act=$(jq -c --argjson iid "$iid" '
      .[] | select(.bindings[]?.inbound_id == $iid)
      | . as $u | (.bindings[] | select(.inbound_id == $iid) | . + {name: $u.name})' "$SB_USERS")
    [ -z "$act" ] && act='[]'
    # 过滤未激活用户（bash 逐个判断）
    local act_final='[]' u
    _sb_tmp2=$(mktemp)
    jq -c '.' <<<"$act" > "$_sb_tmp2" 2>/dev/null
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      local uname=$(jq -r '.name' <<<"$u")
      local full=$(jq -c --arg n "$uname" '.[] | select(.name == $n)' "$SB_USERS")
      if [ -n "$full" ] && user_active "$full"; then
        act_final=$(jq -nc --argjson a "$act_final" --argjson u "$u" '$a + [$u]')
      fi
    done < "$_sb_tmp2"
    rm -f "$_sb_tmp2"
    # stats 用户标签（全局唯一用户名）
    stats_users=$(jq -nc --argjson s "$stats_users" --argjson a "$act_final" '($s + [$a[].name]) | unique')
    local obj=$(render_inbound "$inb" "$act_final")
    [ "$obj" != "null" ] && inbounds_json=$(jq -nc --argjson arr "$inbounds_json" --argjson o "$obj" '$arr + [$o]')
  done < "$_sb_tmp"
  rm -f "$_sb_tmp"

  # 2. 出站
  local outbounds_json='[{"type":"direct","tag":"direct"}]'
  _sb_tmp=$(mktemp)
  jq -c '.[] | {outbound: .outbound}' "$SB_OUTBOUNDS" > "$_sb_tmp" 2>/dev/null
  while IFS= read -r ob; do
    [ -n "$ob" ] && outbounds_json=$(jq -nc --argjson arr "$outbounds_json" --argjson o "$ob" '$arr + [$o.outbound]')
  done < "$_sb_tmp"
  rm -f "$_sb_tmp"

  # 3. 路由：绑定出站的入站 → 指定 outbound；其余 direct
  local rules='[]'
  _sb_tmp=$(mktemp)
  jq -c '.[]' "$SB_INBOUNDS" > "$_sb_tmp" 2>/dev/null
  while IFS= read -r line; do
    local iid=$(jq -r '.id' <<<"$line") obid=$(jq -r '.outbound_id // 0' <<<"$line")
    [ "$obid" != "0" ] && [ "$obid" != "null" ] && \
      rules=$(jq -nc --argjson r "$rules" --argjson i "$iid" --argjson o "$obid" \
        '$r + [{inbound:["in-\($i)"], outbound: ($o | tostring)}]')
  _sb_tmp=$(mktemp)
  jq -c '.[]' "$SB_INBOUNDS" > "$_sb_tmp" 2>/dev/null
  done < "$_sb_tmp"
  rm -f "$_sb_tmp"

  # 4. DNS
  local dns_servers
  dns_servers=$(jq -nc --arg raw "${SB_DNS:-1.1.1.1,8.8.8.8}" '($raw | split(",")) | map({type:"udp", server:.})')

  # 5. 组装（v2ray_api 仅在统计启用时输出——官方核心无此构建 tag 会 check 失败）
  local stats_enabled=${SB_STATS_ENABLED:-0}
  local cfg
  cfg=$(jq -nc \
    --argjson inbounds "$inbounds_json" \
    --argjson outbounds "$outbounds_json" \
    --argjson rules "$rules" \
    --argjson dns "$dns_servers" \
    --argjson stats_users "$stats_users" \
    --arg api_listen "127.0.0.1:$api_port" --arg api_token "$api_token" \
    --argjson se "$stats_enabled" \
    '{log:{level:"warn", timestamp:true},
      dns:{servers:$dns},
      inbounds:$inbounds,
      outbounds:$outbounds,
      route:{rules:$rules, final:"direct", auto_detect_interface:true},
      experimental:(if $se == 1 then {v2ray_api:{listen:$api_listen, stats:{enabled:true, users:$stats_users}}} else {} end)}')
  [ $? -ne 0 ] && { echo "错误: 配置组装失败"; return 1; }

  # 6. check → apply / 回滚
  echo "$cfg" > "$SB_CONFIG.new"
  if "$SB_CORE" check -c "$SB_CONFIG.new" >/dev/null 2>&1; then
    [ -f "$SB_CONFIG" ] && cp "$SB_CONFIG" "$SB_CONFIG_BAK"
    mv "$SB_CONFIG.new" "$SB_CONFIG"
    echo "OK"
  else
    echo "错误: 配置校验失败，已保留原配置。详情:"
    "$SB_CORE" check -c "$SB_CONFIG.new" 2>&1 | head -5
    rm -f "$SB_CONFIG.new"
    return 1
  fi
}

# 应用变更：渲染 + 重启（sing-box 不支持热重载，restart 会断连）
apply_config() {
  local r
  r=$(gen_config) || { echo "$r"; return 1; }
  if pgrep -x sing-box >/dev/null 2>&1 || [ "$(svc_action status)" = "running" ]; then
    svc_action restart >/dev/null 2>&1
    sleep 1
    if pgrep -x sing-box >/dev/null 2>&1; then
      echo "已应用并重启服务"
      sb_log "config applied, service restarted"
    else
      echo "警告: 服务重启后未运行，请检查 journalctl/rc-service 日志"
      sb_log "WARN: service not running after restart"
      return 1
    fi
  else
    echo "已生成配置（服务未运行，未重启）"
  fi
}
