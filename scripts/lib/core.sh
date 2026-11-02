#!/usr/bin/env bash
# core.sh —— 核心安装/更新/卸载、DNS 管理；outbound.sh —— 出站管理
set -u
. /opt/sb-mgr/scripts/lib/common.sh

ask() { read -rp "${1:-}" ans; echo "$ans"; }

GH="https://github.com/SagerNet/sing-box/releases"

core_list_remote() { # 列出最近版本 tag
  curl -fsm 15 "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=20" \
    | jq -r '.[].tag_name' 2>/dev/null
}

core_install() { # <tag|latest|stats>
  local tag=$1 arch repo="SagerNet/sing-box"
  case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) echo "不支持的架构: $(uname -m)"; return 1 ;;
  esac
  # stats = 第三方编译版（Tangfffyx/sing-box，含 with_v2ray_api 按用户流量统计）
  local want_stats=0
  if [ "$tag" = stats ]; then
    repo="Tangfffyx/sing-box"; want_stats=1
    tag=$(curl -fsm 15 "https://api.github.com/repos/$repo/releases/latest" | jq -r '.tag_name')
  elif [ "$tag" = latest ]; then
    tag=$(curl -fsm 15 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | jq -r '.tag_name')
  fi
  [ -z "$tag" ] || [ "$tag" = null ] && { echo "获取版本失败"; return 1; }
  local ver=${tag#v}
  local tmp=$(mktemp -d)
  local url
  if [ "$want_stats" = 1 ]; then
    url="https://github.com/$repo/releases/download/$tag/sing-box-linux-$arch.tar.gz"
  else
    url="$GH/download/$tag/sing-box-$ver-linux-$arch.tar.gz"
  fi
  echo "下载 sing-box $tag (linux-$arch)..."
  if ! curl -fsLm 300 -o "$tmp/sb.tar.gz" "$url"; then
    echo "下载失败"; rm -rf "$tmp"; return 1
  fi
  # checksum 校验
  if curl -fsLm 60 -o "$tmp/sums" "$GH/download/$tag/sing-box-$ver-linux-$arch.tar.gz.sha256sum" 2>/dev/null; then
    (cd "$tmp" && sha256sum -c sums --status 2>/dev/null) || echo "警告: checksum 校验失败（继续安装）"
  else
    echo "警告: 未获取到 checksum"
  fi
  tar xzf "$tmp/sb.tar.gz" -C "$tmp"
  local bin=$(find "$tmp" -name sing-box -type f | head -1)
  [ -z "$bin" ] && { echo "解压失败"; rm -rf "$tmp"; return 1; }
  install -m 755 "$bin" "$SB_CORE" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  echo "已安装: $("$SB_CORE" version | head -1)"
  sb_log "core installed: $tag ($repo)"
  # 统计开关
  if [ "$want_stats" = 1 ]; then
    set_config_env SB_STATS_ENABLED 1
    echo "已启用按用户流量统计（v2ray_api）"
  else
    set_config_env SB_STATS_ENABLED 0
    echo "提示: 此版本不含流量统计 API，流量列将显示「未统计」"
    echo "      如需统计请选「安装统计增强版」"
  fi
  install_service
}

install_service() {
  case "$(detect_init)" in
    systemd)
      cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=$SB_CORE run -c $SB_ETC/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
      cat > /etc/systemd/system/sb-stats.service <<EOF
[Unit]
Description=sb-mgr traffic stats
After=sing-box.service

[Service]
Type=oneshot
ExecStart=/bin/bash $SB_SCRIPTS/sb-stats.sh
EOF
      cat > /etc/systemd/system/sb-stats.timer <<EOF
[Unit]
Description=Run sb-stats every 5 minutes

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
EOF
      systemctl daemon-reload
      systemctl enable --now sing-box 2>/dev/null
      systemctl enable --now sb-stats.timer 2>/dev/null
      ;;
    openrc)
      cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="$SB_CORE"
command_args="run -c $SB_ETC/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() {
  need net
}
EOF
      chmod +x /etc/init.d/sing-box
      rc-update add sing-box default 2>/dev/null
      # stats via crond
      (command -v crond >/dev/null 2>&1 && service crond start 2>/dev/null; rc-update add crond default 2>/dev/null) || true
      (crontab -l 2>/dev/null | grep -v sb-stats; echo "*/5 * * * * /bin/bash $SB_SCRIPTS/sb-stats.sh") | crontab - 2>/dev/null
      ;;
    none) echo "警告: 未检测到 systemd/openrc，请手动运行 sing-box" ;;
  esac
}

core_menu() {
  while :; do
    echo "===== 核心管理 ====="
    echo "当前: $(core_status)"
    echo "1.安装/更新核心  2.卸载核心  3.DNS管理  0.返回"
    case $(ask "选择: ") in
      1)
        echo "(1) 安装最新版本（官方，无流量统计）"
        echo "(2) 安装指定版本（官方）"
        echo "(3) 更新至最新版本（官方）"
        echo "(4) 安装统计增强版（Tangfffyx 编译，含按用户流量统计）"
        local c=$(ask "选择: ")
        case $c in
          1) core_install latest ;;
          2) core_list_remote | head -10; core_install "v$(ask '输入版本号(如 1.12.0): ')" ;;
          3) [ -x "$SB_CORE" ] && core_install latest || echo "未安装，请先安装" ;;
          4) core_install stats ;;
        esac ;;
      2)
        echo "卸载将停止服务并删除二进制，数据目录 $SB_ETC 保留。确认? [y/N]"
        [ "$(ask)" = "y" ] || continue
        svc_action stop; svc_action disable 2>/dev/null
        rm -f "$SB_CORE"; sb_log "core uninstalled"; echo "已卸载" ;;
      3) dns_menu ;;
      0) return ;;
    esac
  done
}

dns_menu() {
  . "$SB_ETC/config.env" 2>/dev/null
  echo "当前 DNS: ${SB_DNS:-1.1.1.1,8.8.8.8}"
  local n=$(ask "新 DNS（逗号分隔，如 1.1.1.1,8.8.8.8）: ")
  [ -z "$n" ] && return
  set_config_env SB_DNS "$n"
  echo "是否立即应用? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

set_config_env() { # <key> <value>
  local k=$1 v=$2 f=$SB_ETC/config.env
  mkdir -p "$SB_ETC"; touch "$f"
  if grep -q "^${k}=" "$f" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=\"${v}\"|" "$f"
  else
    echo "${k}=\"${v}\"" >> "$f"
  fi
}

# ============ 出站管理 ============
outbound_list() {
  if [ "$(jq length "$SB_OUTBOUNDS")" -eq 0 ]; then echo "（空）"; return; fi
  jq -r '.[] | "\(.id)\t\(.name)\t\(.outbound.type)"' "$SB_OUTBOUNDS"
}

# 解析节点链接 → outbound 对象（jq 手工解析常见 URI）
parse_link() { # <link> → stdout outbound JSON
  local link=$1
  case $link in
    ss://*)
      # ss://base64(method:pass)@host:port  或 ss://method:pass@host:port
      local body=${link#ss://}; local frag=${body##*#}; body=${body%%#*}
      local userinfo hostport method pass
      if [[ "$body" == *@* ]]; then
        userinfo=${body%%@*}; hostport=${body##*@}
        if [[ "$userinfo" != *:* && "$userinfo" != *"2022-"* ]]; then
          local dec; dec=$(printf '%s' "$userinfo" | base64 -d 2>/dev/null)
          [[ "$dec" == *:* ]] && userinfo=$dec
        fi
        method=${userinfo%%:*}; pass=${userinfo#*:}
      else
        local dec; dec=$(printf '%s' "$body" | base64 -d 2>/dev/null)
        [[ "$dec" == *"@"* ]] || { echo "PARSE_FAIL"; return; }
        method=$(printf '%s' "$dec" | cut -d: -f1); pass=$(printf '%s' "$dec" | cut -d: -f2- | cut -d@ -f1)
        hostport=$(printf '%s' "$dec" | cut -d@ -f2-)
      fi
      [[ "$body" == *@* ]] && hostport=${body##*@}
      local host=${hostport%%:*} port=${hostport##*:}
      jq -nc --arg m "$method" --arg p "$pass" --arg h "$host" --argjson pt "$port" \
        '{type:"shadowsocks", server:$h, server_port:$pt, method:$m, password:$p}'
      ;;
    trojan://*)
      local body=${link#trojan://}; local frag=${body##*#}; body=${body%%#*}
      local pass=${body%%@*}; local hostport=$(printf '%s' "$body" | cut -d@ -f2- | cut -d? -f1)
      local query=${body##*[?]} port=443 sni=""
      [[ "$body" == *\?* ]] && { port=$(printf '%s' "$query" | grep -o 'port=[0-9]*' | cut -d= -f2); sni=$(printf '%s' "$query" | grep -o 'sni=[^&]*' | cut -d= -f2); }
      local host=${hostport%%:*}; [[ "$hostport" == *:* ]] && port=${hostport##*:}
      jq -nc --arg p "$pass" --arg h "$host" --argjson pt "${port:-443}" --arg sni "$sni" --arg tag "$frag" \
        '{type:"trojan", tag:$tag, server:$h, server_port:$pt, password:$p,
          tls:({enabled:true} + (if $sni != "" then {server_name:$sni} else {} end))}'
      ;;
    vless://*)
      local body=${link#vless://}; local frag=${body##*#}; body=${body%%#*}
      local uuid=${body%%@*}; local rest=${body##*@}
      local hostport=${rest%%\?*}; local query=${rest#*\?}
      local host=${hostport%%:*} port=${hostport##*:}
      local type=$(printf '%s' "$query" | grep -o 'type=[^&]*' | cut -d= -f2); type=${type:-tcp}
      local security=$(printf '%s' "$query" | grep -o 'security=[^&]*' | cut -d= -f2)
      local sni=$(printf '%s' "$query" | grep -o 'sni=[^&]*' | cut -d= -f2)
      local flow=$(printf '%s' "$query" | grep -o 'flow=[^&]*' | cut -d= -f2)
      local pbk=$(printf '%s' "$query" | grep -o 'pbk=[^&]*' | cut -d= -f2)
      local sid=$(printf '%s' "$query" | grep -o 'sid=[^&]*' | cut -d= -f2)
      local path=$(printf '%s' "$query" | grep -o 'path=[^&]*' | cut -d= -f2)
      local sn=$(printf '%s' "$query" | grep -o 'serviceName=[^&]*' | cut -d= -f2)
      jq -nc --arg uuid "$uuid" --arg h "$host" --argjson pt "$port" --arg type "$type" \
        --arg sec "$security" --arg sni "$sni" --arg flow "$flow" --arg pbk "$pbk" \
        --arg sid "$sid" --arg path "$path" --arg sn "$sn" --arg tag "$frag" '
        {type:"vless", tag:$tag, server:$h, server_port:$pt, uuid:$uuid}
        + (if $flow != "" then {flow:$flow} else {} end)
        + (if $type == "ws" then {transport:{type:"ws", path:(if $path != "" then $path else "/" end)}} else {} end)
        + (if $type == "grpc" then {transport:{type:"grpc", service_name:$sn}} else {} end)
        + (if $sec == "tls" or $sec == "reality" then {tls:({enabled:true, utls:{enabled:true, fingerprint:"chrome"}} + (if $sni != "" then {server_name:$sni} else {} end))} else {} end)
        + (if $sec == "reality" then {tls:{reality:{enabled:true, public_key:$pbk, short_id:$sid}}} else {} end)'
      ;;
    hy2://*|hysteria2://*)
      local body=${link#*://}; local frag=${body##*#}; body=${body%%#*}
      local pass=${body%%@*}; local rest=${body##*@}
      local hostport=${rest%%\?*}; local query=${rest#*\?}
      local host=${hostport%%:*} port=${hostport##*:}
      local sni=$(printf '%s' "$query" | grep -o 'sni=[^&]*' | cut -d= -f2)
      local insec=$(printf '%s' "$query" | grep -o 'insecure=[^&]*' | cut -d= -f2)
      jq -nc --arg p "$pass" --arg h "$host" --argjson pt "$port" --arg sni "$sni" --arg insec "$insec" --arg tag "$frag" \
        '{type:"hysteria2", tag:$tag, server:$h, server_port:$pt, password:$p,
          tls:({enabled:true} + (if $sni != "" then {server_name:$sni} else {} end)
                + (if $insec == "1" or $insec == "true" then {insecure:true} else {} end))}'
      ;;
    tuic://*)
      local body=${link#tuic://}; local frag=${body##*#}; body=${body%%#*}
      local cred=${body%%@*}; local rest=${body##*@}
      local hostport=${rest%%\?*}; local query=${rest#*\?}
      local uuid=${cred%%:*} pass=${cred#*:}
      local host=${hostport%%:*} port=${hostport##*:}
      local sni=$(printf '%s' "$query" | grep -o 'sni=[^&]*' | cut -d= -f2)
      jq -nc --arg u "$uuid" --arg p "$pass" --arg h "$host" --argjson pt "$port" --arg sni "$sni" --arg tag "$frag" \
        '{type:"tuic", tag:$tag, server:$h, server_port:$pt, uuid:$u, password:$p,
          tls:({enabled:true} + (if $sni != "" then {server_name:$sni} else {} end))}'
      ;;
    *) echo "UNSUPPORTED" ;;
  esac
}

outbound_add() {
  echo "粘贴节点链接（ss/trojan/vless/hy2/tuic，不支持订阅链接）:"
  local link=$(ask "> ")
  [ -z "$link" ] && return
  local ob=$(parse_link "$link")
  [ "$ob" = UNSUPPORTED ] || [ "$ob" = PARSE_FAIL ] || [ -z "$ob" ] && { echo "链接解析失败"; return; }
  if ! jq empty <<<"$ob" 2>/dev/null; then echo "解析结果非法"; return; fi
  local name=$(ask "出站名称 [$(jq -r '.tag // "out"' <<<"$ob")]: ")
  name=${name:-$(jq -r '.tag // "out"' <<<"$ob")}
  local id=$(sdb_next_id "$SB_OUTBOUNDS")
  # tag 统一为 out-<id> 避免冲突
  ob=$(jq --arg t "out-$id" '.tag=$t' <<<"$ob")
  jq -nc --argjson id "$id" --arg name "$name" --argjson o "$ob" \
    '{id:$id,name:$name,outbound:$o}' | jq --slurpfile f "$SB_OUTBOUNDS" '$f[0] + [input]' 2>/dev/null \
    | sdb_write "$SB_OUTBOUNDS" || { echo "写入失败"; return 1; }
  sb_log "outbound added: $name"
  echo "已添加。是否立即应用? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

outbound_del() {
  outbound_list
  local id=$(ask "删除出站序号: ")
  jq -e --argjson i "$id" 'select(.id==$i)' "$SB_OUTBOUNDS" | grep -q . || { echo "不存在"; return; }
  echo "确认删除? [y/N]"
  [ "$(ask)" = "y" ] || return
  # 级联清空入站的出站绑定
  jq --argjson i "$id" 'map(if .outbound_id == $i then .outbound_id = null else . end)' "$SB_INBOUNDS" | sdb_write "$SB_INBOUNDS"
  jq --argjson i "$id" 'map(select(.id != $i))' "$SB_OUTBOUNDS" | sdb_write "$SB_OUTBOUNDS"
  sb_log "outbound deleted: id=$id"
  echo "是否立即应用? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

outbound_test() {
  outbound_list
  local id=$(ask "测试出站序号: ")
  local ob=$(jq -c --argjson i "$id" '.[] | select(.id==$i)' "$SB_OUTBOUNDS")
  [ -z "$ob" ] || [ "$ob" = null ] && { echo "不存在"; return; }
  local tport=18080
  local tcfg=$(mktemp)
  jq -nc --argjson o "$(jq -c '.outbound' <<<"$ob")" --argjson tp "$tport" \
    '{log:{level:"fatal"},
      inbounds:[{type:"mixed", tag:"test", listen:"127.0.0.1", listen_port:$tp}],
      outbounds:[$o, {type:"direct", tag:"direct"}],
      route:{final:"out-"}}' <<<"$(jq -c '.outbound' <<<"$ob")" > "$tcfg" 2>/dev/null
  # 修正: final 应为出站 tag
  jq --arg t "$(jq -r '.outbound.tag' <<<"$ob")" '.route.final=$t' "$tcfg" > "$tcfg.2" && mv "$tcfg.2" "$tcfg"
  "$SB_CORE" run -c "$tcfg" >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  local t0=$(date +%s%N 2>/dev/null || date +%s)
  if curl -fsm 10 -x "http://127.0.0.1:$tport" -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 >/dev/null 2>&1; then
    local t1=$(date +%s%N 2>/dev/null || date +%s)
    echo "✓ 连通，延迟 $(( (t1 - t0) / 1000000 ))ms"
  else
    echo "✗ 不通"
  fi
  kill "$pid" 2>/dev/null; rm -f "$tcfg"
}

outbound_bind() {
  echo "--- 入站列表 ---"
  jq -r '.[] | "\(.id)\t\(.name)\t当前出站: \(if .outbound_id then "out-\(.outbound_id)" else "direct" end)"' "$SB_INBOUNDS"
  local iid=$(ask "入站序号: ")
  jq -e --argjson i "$iid" 'select(.id==$i)' "$SB_INBOUNDS" | grep -q . || { echo "不存在"; return; }
  echo "--- 出站列表 ---"; outbound_list
  echo "0. 解绑（直连）"
  local oid=$(ask "出站序号: ")
  if [ "$oid" = 0 ]; then
    jq --argjson i "$iid" 'map(if .id==$i then .outbound_id=null else . end)' "$SB_INBOUNDS" | sdb_write "$SB_INBOUNDS"
  else
    jq -e --argjson i "$oid" 'select(.id==$i)' "$SB_OUTBOUNDS" | grep -q . || { echo "出站不存在"; return; }
    jq --argjson i "$iid" --argjson o "$oid" 'map(if .id==$i then .outbound_id=$o else . end)' "$SB_INBOUNDS" | sdb_write "$SB_INBOUNDS"
  fi
  echo "是否立即应用? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

outbound_menu() {
  while :; do
    echo "===== 出站列表 ====="; outbound_list
    echo "1.添加出站  2.删除出站  3.出站测试  4.出站绑定  0.返回"
    case $(ask "选择: ") in
      1) outbound_add ;;
      2) outbound_del ;;
      3) outbound_test ;;
      4) outbound_bind ;;
      0) return ;;
    esac
  done
}
