#!/usr/bin/env bash
# inbound.sh —— 入站管理（10 协议模板）
set -u
. /opt/sb-mgr/scripts/lib/common.sh

PROTOS=(
  "vless-reality|VLESS + TCP + Reality + Vision"
  "vless-ws|VLESS + WebSocket + TLS"
  "trojan-ws|Trojan + WebSocket + TLS"
  "vless-grpc|VLESS + gRPC + TLS"
  "anytls|AnyTLS"
  "hysteria2|Hysteria2"
  "tuic|TUICv5"
  "shadowsocks|Shadowsocks"
  "vless-tcp|VLESS + TCP（明文）"
  "socks|SOCKS5"
)

ask() { read -rp "${1:-}" ans; echo "$ans"; }

# 公共输入
ask_port() {
  local p
  while :; do p=$(ask "监听端口 [443]: "); [ -z "$p" ] && p=443
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then echo "$p"; return; fi
    echo "端口无效"; done
}
ask_listen() { local l=$(ask "监听 IP [0.0.0.0]: "); echo "${l:-0.0.0.0}"; }
ask_tls_files() { # 输出 "cert|key"
  local c k
  c=$(ask "TLS 证书路径 (pem): "); k=$(ask "TLS 私钥路径: ")
  while [ ! -f "$c" ] || [ ! -f "$k" ]; do
    echo "证书或私钥文件不存在，请重试（留空跳过=无法启动 TLS 入站）"
    c=$(ask "TLS 证书路径 (pem): "); k=$(ask "TLS 私钥路径: ")
    [ -z "$c" ] && break
  done
  echo "$c|$k"
}

inbound_list_menu() {
  echo "--- 入站列表 ---"
  if [ "$(jq length "$SB_INBOUNDS")" -eq 0 ]; then echo "（空）"; return; fi
  jq -r --argjson users "$(cat "$SB_USERS")" -f- "$SB_INBOUNDS" <<'EOF' 2>/dev/null || \
  jq -r '.[] | "\(.id)\t\(.name)\t\(.proto)\t0"' "$SB_INBOUNDS"
def pname: .proto;
.[] | . as $i |
  ($users | map(select(.bindings[]?.inbound_id == $i.id)) | length) as $n |
  "\($i.id)\t\($i.name)\t\($i.proto)\t\($n)"
EOF
  echo "（序号  名称  协议  绑定用户数）"
}

inbound_add() {
  echo "===== 添加入站 ====="
  local i=1 p sel=""
  for p in "${PROTOS[@]}"; do echo "$i. ${p#*|}"; i=$((i+1)); done
  local idx=$(ask "选择协议 [1]: "); [ -z "$idx" ] && idx=1
  [ "$idx" -ge 1 ] && [ "$idx" -le ${#PROTOS[@]} ] 2>/dev/null || { echo "无效选择"; return; }
  sel="${PROTOS[$((idx-1))]}"; local proto=${sel%%|*}

  local name=$(ask "入站名称: ")
  [ -z "$name" ] && { echo "名称不能为空"; return; }
  local port=$(ask_port) listen=$(ask_listen)
  local obj id=$(sdb_next_id "$SB_INBOUNDS")

  case $proto in
    vless-reality)
      local sni=$(ask "Reality SNI/目标站点 (如 www.yahoo.com): ")
      local kp
      if [ -x "$SB_CORE" ]; then kp=$("$SB_CORE" generate reality-keypair 2>/dev/null); fi
      local pk sid
      pk=$(printf '%s' "$kp" | sed -n 's/PrivateKey:[[:space:]]*//p')
      [ -z "$pk" ] && { echo "生成 Reality 密钥失败（需先安装核心）"; return; }
      sid=$(gen_short_id)
      obj=$(jq -nc --argjson id "$id" --arg name "$name" --arg proto "$proto" \
        --arg listen "$listen" --argjson port "$port" --arg sni "$sni" \
        --arg dest "${sni}:443" --arg pk "$pk" --arg sid "$sid" \
        '{id:$id,name:$name,proto:$proto,listen:$listen,port:$port,
          reality:{sni:$sni,dest:$dest,private_key:$pk,short_id:$sid}}')
      local pub; pub=$(printf '%s' "$kp" | sed -n 's/PublicKey:[[:space:]]*//p')
      echo "Reality 公钥: $pub（请保存，客户端需要）"
      # 公钥存入 state.json 供订阅链接生成使用
      jq --argjson i "$id" --arg pub "$pub" \
         '.reality_pub[$i | tostring] = $pub' "$SB_STATE" 2>/dev/null | sdb_write "$SB_STATE" || true
      ;;
    vless-ws|trojan-ws)
      local path=$(ask "WebSocket 路径 [/${proto}-ws]: "); [ -z "$path" ] && path="/${proto}-ws"
      local sni=$(ask "TLS SNI（可空）: ")
      local ck=$(ask_tls_files); local cert=${ck%|*} key=${ck#*|}
      if [ "$proto" = vless-ws ]; then
        obj=$(jq -nc --argjson id "$id" --arg name "$name" --arg proto "$proto" \
          --arg listen "$listen" --argjson port "$port" --arg path "$path" \
          --arg sni "$sni" --arg cert "$cert" --arg key "$key" \
          '{id:$id,name:$name,proto:$proto,listen:$listen,port:$port,ws:{path:$path},
            tls:{sni:$sni,cert:$cert,key:$key}}')
      else
        obj=$(jq -nc --argjson id "$id" --arg name "$name" --arg proto "$proto" \
          --arg listen "$listen" --argjson port "$port" --arg path "$path" \
          --arg sni "$sni" --arg cert "$cert" --arg key "$key" \
          '{id:$id,name:$name,proto:$proto,listen:$listen,port:$port,ws:{path:$path},
            tls:{sni:$sni,cert:$cert,key:$key}}')
      fi
      ;;
    vless-grpc)
      local sn=$(ask "gRPC serviceName: ")
      local sni=$(ask "TLS SNI（可空）: ")
      local ck=$(ask_tls_files); local cert=${ck%|*} key=${ck#*|}
      obj=$(jq -nc --argjson id "$id" --arg name "$name" --arg proto "$proto" \
        --arg listen "$listen" --argjson port "$port" --arg sn "$sn" \
        --arg sni "$sni" --arg cert "$cert" --arg key "$key" \
        '{id:$id,name:$name,proto:$proto,listen:$listen,port:$port,
          grpc:{service_name:$sn},tls:{sni:$sni,cert:$cert,key:$key}}')
      ;;
    anytls|hysteria2|tuic)
      local sni=$(ask "TLS SNI（可空）: ")
      local ck=$(ask_tls_files); local cert=${ck%|*} key=${ck#*|}
      local extra='{}'
      if [ "$proto" = hysteria2 ]; then
        local up=$(ask "上行 Mbps [100]: "); [ -z "$up" ] && up=100
        local down=$(ask "下行 Mbps [100]: "); [ -z "$down" ] && down=100
        local hop=$(ask "端口跳跃范围 (如 20000-30000，可空=不开启): ")
        extra=$(jq -nc --argjson up "$up" --argjson down "$down" --arg hop "$hop" \
          '{up_mbps:$up,down_mbps:$down,hop_ports:$hop}')
      fi
      if [ "$proto" = tuic ]; then
        local cc=$(ask "拥塞控制 bbr/cubic [bbr]: "); [ -z "$cc" ] && cc=bbr
        extra=$(jq -nc --arg cc "$cc" '{congestion_control:$cc}')
      fi
      obj=$(jq -nc --argjson id "$id" --arg name "$name" --arg proto "$proto" \
        --arg listen "$listen" --argjson port "$port" --arg sni "$sni" \
        --arg cert "$cert" --arg key "$key" --argjson extra "$extra" \
        '{id:$id,name:$name,proto:$proto,listen:$listen,port:$port,
          tls:{sni:$sni,cert:$cert,key:$key}} + $extra')
      ;;
    shadowsocks)
      echo "加密方式: 1. 2022-blake3-aes-128-gcm  2. 2022-blake3-aes-256-gcm"
      local m=$(ask "选择 [1]: "); [ -z "$m" ] && m=1
      local method keylen
      [ "$m" = 2 ] && { method=2022-blake3-aes-256-gcm; keylen=32; } || { method=2022-blake3-aes-128-gcm; keylen=16; }
      local skey=$(gen_ss2022_key "$keylen")
      echo "服务端主密钥: $skey（绑定用户时生成的密码=主密钥:用户密钥，客户端使用拼接后的完整值）"
      obj=$(jq -nc --argjson id "$id" --arg name "$name" --arg proto "$proto" \
        --arg listen "$listen" --argjson port "$port" --arg method "$method" --arg skey "$skey" \
        '{id:$id,name:$name,proto:$proto,listen:$listen,port:$port,
          ss2022:{method:$method,server_key:$skey}}')
      ;;
    vless-tcp)
      obj=$(jq -nc --argjson id "$id" --arg name "$name" --arg proto "$proto" \
        --arg listen "$listen" --argjson port "$port" \
        '{id:$id,name:$name,proto:$proto,listen:$listen,port:$port}')
      ;;
    socks)
      obj=$(jq -nc --argjson id "$id" --arg name "$name" --arg proto "$proto" \
        --arg listen "$listen" --argjson port "$port" \
        '{id:$id,name:$name,proto:$proto,listen:$listen,port:$port}')
      ;;
    *) echo "未知协议"; return ;;
  esac

  jq --argjson o "$obj" '. + [$o]' "$SB_INBOUNDS" | sdb_write "$SB_INBOUNDS" || { echo "写入失败"; return 1; }
  sb_log "inbound added: $name ($proto:$port)"
  # hy2 端口跳跃防火墙规则
  local hop=$(jq -r --argjson id "$id" '.[] | select(.id==$id) | .hop_ports // ""' "$SB_INBOUNDS")
  [ -n "$hop" ] && [ "$hop" != "null" ] && apply_hop_rules add "$port" "$hop"
  echo "入站已添加。是否立即应用配置? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

# hy2 端口跳跃 nftables/iptables 规则
apply_hop_rules() { # <add|del> <主端口> <范围>
  local act=$1 port=$2 range=$3
  if command -v nft >/dev/null 2>&1; then
    if [ "$act" = add ]; then
      nft add table ip sb-hop 2>/dev/null
      nft add chain ip sb-hop prerouting '{ type nat hook prerouting priority -100; }' 2>/dev/null
      nft add rule ip sb-hop prerouting udp dport "$range" dnat to ":$port"
    else
      nft delete table ip sb-hop 2>/dev/null
    fi
  elif command -v iptables >/dev/null 2>&1; then
    if [ "$act" = add ]; then
      iptables -t nat -C PREROUTING -p udp --dport "${range%-*}:${range#*-}" -j REDIRECT --to-ports "$port" 2>/dev/null || \
      iptables -t nat -A PREROUTING -p udp --dport "${range%-*}:${range#*-}" -j REDIRECT --to-ports "$port"
    else
      iptables -t nat -D PREROUTING -p udp --dport "${range%-*}:${range#*-}" -j REDIRECT --to-ports "$port" 2>/dev/null
    fi
  else
    echo "警告: 未找到 nftables/iptables，端口跳跃未生效"
  fi
}

inbound_edit() {
  inbound_list_menu
  local id=$(ask "编辑入站序号: ")
  local inb=$(jq -c --argjson i "$id" '.[] | select(.id==$i)' "$SB_INBOUNDS")
  [ -z "$inb" ] || [ "$inb" = null ] && { echo "不存在"; return; }
  local proto=$(jq -r '.proto' <<<"$inb")
  echo "当前协议: $proto（协议类型不可更改，如需更换请删除重建）"
  local name=$(ask "新名称 [$(jq -r .name <<<"$inb")]: ")
  local port=$(ask "新端口 [$(jq -r .port <<<"$inb")]: ")
  local upd=$(jq -c --argjson i "$id" --arg n "${name:-$(jq -r .name <<<"$inb")}" \
    --argjson p "${port:-$(jq -r .port <<<"$inb")}" \
    'map(if .id==$i then .name=$n | .port=$p else . end)' "$SB_INBOUNDS")
  echo "$upd" | sdb_write "$SB_INBOUNDS" || return 1
  sb_log "inbound edited: id=$id"
  echo "是否立即应用? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

inbound_del() {
  inbound_list_menu
  local id=$(ask "删除入站序号: ")
  local inb=$(jq -c --argjson i "$id" '.[] | select(.id==$i)' "$SB_INBOUNDS")
  [ -z "$inb" ] || [ "$inb" = null ] && { echo "不存在"; return; }
  local nbound=$(jq --argjson i "$id" '[.[] | select(.bindings[]?.inbound_id == $i)] | length' "$SB_USERS")
  [ "$nbound" -gt 0 ] && echo "⚠ 该入站已绑定 $nbound 个用户，删除后将从这些用户中级联解除绑定"
  echo "确认删除? [y/N]"
  [ "$(ask)" = "y" ] || { echo "已取消"; return; }
  # 级联删除用户绑定
  jq --argjson i "$id" 'map(.bindings |= map(select(.inbound_id != $i)))' "$SB_USERS" | sdb_write "$SB_USERS"
  # 端口跳跃规则清理
  local hop=$(jq -r '.hop_ports // ""' <<<"$inb")
  [ -n "$hop" ] && [ "$hop" != "null" ] && apply_hop_rules del "$(jq -r .port <<<"$inb")" "$hop"
  jq --argjson i "$id" 'map(select(.id != $i))' "$SB_INBOUNDS" | sdb_write "$SB_INBOUNDS"
  sb_log "inbound deleted: id=$id (cascade unbound $nbound users)"
  echo "是否立即应用? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

inbound_menu() {
  while :; do
    ui_title "入站管理"
    inbound_list_menu
    echo
    menu_item "1" "添加入站"
    menu_item "2" "编辑入站"
    menu_item "3" "删除入站"
    echo
    printf "  ${C_RED}[0]${C_RESET} 返回上级\n"
    echo
    case $(ask "请选择: ") in
      1) inbound_add ;;
      2) inbound_edit ;;
      3) inbound_del ;;
      0) return ;;
    esac
  done
}
