#!/usr/bin/env bash
# user.sh —— 用户管理、绑定入站、订阅生成
set -u
. /opt/sb-mgr/scripts/lib/common.sh

ask() { read -rp "${1:-}" ans; echo "$ans"; }

user_list_simple() {
  if [ "$(jq length "$SB_USERS")" -eq 0 ]; then echo "（无用户）"; return 1; fi
  jq -r '.[] | "\(.id)\t\(.name)"' "$SB_USERS"
}

user_list_full() {
  if [ "$(jq length "$SB_USERS")" -eq 0 ]; then echo "（无用户）"; return; fi
  local stat_note=""
  [ "${SB_STATS_ENABLED:-0}" != "1" ] && stat_note="1"
  local u
  _sb_tmp=$(mktemp)
  jq -c '.[]' "$SB_USERS" > "$_sb_tmp" 2>/dev/null
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    local name expiry quota used reset bindings
    name=$(jq -r '.name' <<<"$u"); expiry=$(jq -r '.expiry // "永久"' <<<"$u")
    quota=$(jq -r '.quota_bytes // 0' <<<"$u"); used=$(jq -r '.used_bytes // 0' <<<"$u")
    reset=$(jq -r '.reset_day // 1' <<<"$u")
    bindings=$(jq -r '[.bindings[]?.inbound_id] | length' <<<"$u")
    local remain=$(user_remaining_days "$expiry")
    local qleft="不限"
    [ "$quota" -gt 0 ] && qleft="$(fmt_bytes $((quota - used)))（已用 $(fmt_bytes "$used")）"
    printf "  用户 %s｜剩余 %s｜剩余流量 %s｜重置日 每月%s日｜绑定 %s 个入站\n" \
      "$name" "$remain" "$qleft" "$reset" "$bindings"
  done < "$_sb_tmp"
  rm -f "$_sb_tmp"
  [ "${stat_note:-}" = "1" ] && echo "  （提示: 未安装统计增强版核心，流量列不会更新）"
}

user_add() {
  local name=$(ask "用户名称: ")
  [ -z "$name" ] && { echo "名称不能为空"; return; }
  if jq -e --arg n "$name" '.[] | select(.name==$n)' "$SB_USERS" | grep -q .; then
    echo "错误: 用户名已存在（须全局唯一，流量统计按用户名计数）"; return
  fi
  local quota=$(ask "流量配额 GB（0=不限）: "); [ -z "$quota" ] && quota=0
  local expiry=$(ask "到期日期 YYYY-MM-DD（留空=永久）: ")
  local reset=$(ask "流量重置日 1-28（自然月，默认1）: "); [ -z "$reset" ] && reset=1
  [[ "$reset" =~ ^[0-9]+$ ]] && [ "$reset" -ge 1 ] && [ "$reset" -le 28 ] 2>/dev/null || reset=1
  local id=$(sdb_next_id "$SB_USERS")
  local token=$(gen_uuid | tr -d '-')
  # 追加到 users.json
  local nu=$(jq -nc --argjson id "$id" --arg name "$name" \
    --argjson quota "$((quota * 1073741824))" --arg expiry "$expiry" \
    --argjson reset "$reset" --arg token "$token" \
    '{id:$id,name:$name,quota_bytes:$quota,expiry:(if $expiry=="" then null else $expiry end),
      reset_day:$reset,used_bytes:0,sub_token:$token,bindings:[]}')
  jq --argjson u "$nu" '. + [$u]' "$SB_USERS" | sdb_write "$SB_USERS" || { echo "写入失败"; return 1; }
  sb_log "user added: $name"
  echo "用户已添加。可在「绑定入站」为其生成凭证。"
}

user_edit() {
  user_list_simple || return
  local id=$(ask "编辑用户序号: ")
  local u=$(jq -c --argjson i "$id" '.[] | select(.id==$i)' "$SB_USERS")
  [ -z "$u" ] || [ "$u" = null ] && { echo "不存在"; return; }
  local name=$(jq -r .name <<<"$u")
  echo "编辑用户: $name"
  local nname=$(ask "新名称 [留空不变]: ")
  local nquota=$(ask "新配额 GB [留空不变，当前 $(jq -r '.quota_bytes' <<<"$u") bytes]: ")
  local nexpiry=$(ask "新到期日 [留空不变，当前 $(jq -r '.expiry // "永久"' <<<"$u")]: ")
  local nreset=$(ask "新重置日 1-28 [留空不变，当前 $(jq -r .reset_day <<<"$u")]: ")
  # 名称唯一性校验
  if [ -n "$nname" ] && jq -e --arg n "$nname" --argjson i "$id" '.[] | select(.name==$n and .id != $i)' "$SB_USERS" | grep -q .; then
    echo "错误: 新名称与其他用户冲突"; return
  fi
  local upd
  upd=$(jq --argjson i "$id" --arg n "${nname:-$name}" '
    map(if .id==$i then .name=$n else . end)' "$SB_USERS")
  [ -n "$nquota" ] && upd=$(jq --argjson i "$id" --argjson q "$((nquota * 1073741824))" 'map(if .id==$i then .quota_bytes=$q else . end)' <<<"$upd")
  [ -n "$nexpiry" ] && upd=$(jq --argjson i "$id" --arg e "$nexpiry" 'map(if .id==$i then .expiry=$e else . end)' <<<"$upd")
  [ -n "$nreset" ] && upd=$(jq --argjson i "$id" --argjson r "$nreset" 'map(if .id==$i then .reset_day=$r else . end)' <<<"$upd")
  echo "$upd" | sdb_write "$SB_USERS" || { echo "写入失败"; return 1; }
  sb_log "user edited: id=$id"
  echo "是否立即应用? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

# 绑定入站：凭证在此生成（核心需求）
user_bind() {
  user_list_simple || return
  local uid=$(ask "选择用户序号: ")
  local u=$(jq -c --argjson i "$uid" '.[] | select(.id==$i)' "$SB_USERS")
  [ -z "$u" ] || [ "$u" = null ] && { echo "不存在"; return; }
  local uname=$(jq -r .name <<<"$u")
  if [ "$(jq length "$SB_INBOUNDS")" -eq 0 ]; then echo "无入站可绑定，请先添加入站"; return; fi
  echo "--- 入站列表 ---"
  jq -r --argjson u "$u" '.[] | "\(.id)\t\(.name)\t\(.proto)\t\(if ($u.bindings[]?.inbound_id == .id) then "已绑定" else "" end)"' "$SB_INBOUNDS" | column -t 2>/dev/null || \
  jq -r --argjson u "$u" '.[] | "\(.id)  \(.name)  \(.proto)"' "$SB_INBOUNDS"
  local iid=$(ask "绑定入站序号: ")
  local inb=$(jq -c --argjson i "$iid" '.[] | select(.id==$i)' "$SB_INBOUNDS")
  [ -z "$inb" ] || [ "$inb" = null ] && { echo "入站不存在"; return; }
  local proto=$(jq -r .proto <<<"$inb")

  # 检查重复绑定
  jq -e --argjson uid "$uid" --argjson iid "$iid" '.[] | select(.id==$uid) | .bindings[]? | select(.inbound_id==$iid)' "$SB_USERS" | grep -q . && {
    echo "该用户已绑定此入站"; return; }

  # ===== 按协议生成凭证 =====
  local cred
  case $proto in
    vless-*)    cred=$(jq -nc --argjson iid "$iid" '{inbound_id:$iid,uuid:"'"$(gen_uuid)"'"}') ;;
    trojan-ws|anytls)
                cred=$(jq -nc --argjson iid "$iid" '{inbound_id:$iid,password:"'"$(gen_pass 16)"'"}') ;;
    hysteria2)  cred=$(jq -nc --argjson iid "$iid" '{inbound_id:$iid,password:"'"$(gen_pass 16)"'"}') ;;
    tuic)       cred=$(jq -nc --argjson iid "$iid" '{inbound_id:$iid,uuid:"'"$(gen_uuid)"'",password:"'"$(gen_pass 16)"'"}') ;;
    shadowsocks)
                local keylen=16
                [ "$(jq -r '.ss2022.method' <<<"$inb")" = 2022-blake3-aes-256-gcm ] && keylen=32
                local ukey=$(gen_ss2022_key "$keylen")
                local mk=$(jq -r '.ss2022.server_key' <<<"$inb")
                echo "提示: SS2022 客户端密码 = 主密钥:用户密钥（链接中已拼接）"
                cred=$(jq -nc --argjson iid "$iid" '{inbound_id:$iid,password:"'"$ukey"'",full_password:"'"$mk:$ukey"'"}') ;;
    socks)      cred=$(jq -nc --argjson iid "$iid" '{inbound_id:$iid,socks_user:"'"$(gen_pass 8)"'",socks_pass:"'"$(gen_pass 16)"'"}') ;;
  esac
  [ -z "$cred" ] && { echo "不支持的协议"; return; }

  jq --argjson uid "$uid" --argjson c "$cred" \
     'map(if .id==$uid then .bindings += [$c] else . end)' "$SB_USERS" \
     | sdb_write "$SB_USERS" || { echo "写入失败"; return 1; }
  sb_log "user $uname bound inbound $iid ($proto)"

  # 生成订阅文件
  gen_user_sub "$uid"

  echo "是否立即应用? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

# 解绑
user_unbind() {
  user_list_simple || return
  local uid=$(ask "用户序号: ")
  jq -e --argjson i "$uid" 'select(.id==$i)' "$SB_USERS" | grep -q . || { echo "不存在"; return; }
  local u=$(jq -c --argjson i "$uid" '.[] | select(.id==$i)' "$SB_USERS")
  jq -r '.bindings[] | "\(.inbound_id)"' <<<"$u" | head -20
  local iid=$(ask "解绑入站序号: ")
  jq --argjson uid "$uid" --argjson iid "$iid" \
     'map(if .id==$uid then .bindings |= map(select(.inbound_id != $iid)) else . end)' "$SB_USERS" \
     | sdb_write "$SB_USERS" || return 1
  gen_user_sub "$uid"
  echo "已解绑。是否立即应用? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

user_del() {
  user_list_simple || return
  local uid=$(ask "删除用户序号: ")
  jq -e --argjson i "$uid" 'select(.id==$i)' "$SB_USERS" | grep -q . || { echo "不存在"; return; }
  echo "确认删除? [y/N]"
  [ "$(ask)" = "y" ] || return
  jq --argjson i "$uid" 'map(select(.id != $i))' "$SB_USERS" | sdb_write "$SB_USERS"
  sb_log "user deleted: id=$uid"
  echo "是否立即应用? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

# ===== 订阅链接生成 =====
gen_node_link() { # <user对象> <binding对象> <inbound对象> → stdout 链接
  local u=$1 b=$2 inb=$3
  local proto=$(jq -r .proto <<<"$inb") port=$(jq -r .port <<<"$inb")
  local ip=$(jq -r '.server_ip // ""' <<<"$inb"); [ -z "$ip" ] || [ "$ip" = null ] && ip=$(get_public_ip)
  local name=$(jq -r .name <<<"$u") iname=$(jq -r .name <<<"$inb")
  local tag="${name}-${iname}"
  case $proto in
    vless-reality)
      local uuid=$(jq -r .uuid <<<"$b")
      local pbk=""
      # 公钥需从 state 中取（添加入站时保存）
      pbk=$(jq -r --argjson i "$(jq -r .id <<<"$inb")" '.reality_pub["\($i)"] // ""' "$SB_STATE")
      local sni=$(jq -r .reality.sni <<<"$inb") sid=$(jq -r .reality.short_id <<<"$inb")
      echo "vless://${uuid}@${ip}:${port}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp&flow=xtls-rprx-vision#${tag}"
      ;;
    vless-ws)
      local uuid=$(jq -r .uuid <<<"$b") path=$(jq -r .ws.path <<<"$inb")
      local tls_p=""; [ -n "$(jq -r '.tls.cert // ""' <<<"$inb")" ] && tls_p="&security=tls"
      echo "vless://${uuid}@${ip}:${port}?encryption=none${tls_p}&type=ws&path=${path}#${tag}"
      ;;
    trojan-ws)
      local pw=$(jq -r .password <<<"$b") path=$(jq -r .ws.path <<<"$inb")
      local tls_p=""; [ -n "$(jq -r '.tls.cert // ""' <<<"$inb")" ] && tls_p="?security=tls"
      echo "trojan://${pw}@${ip}:${port}${tls_p}${tls_p:+&}type=ws&path=${path}#${tag}" | sed 's|?security=tls&|?security=tls\&|;s|^trojan://\([^?]*\)$|trojan://\1|'
      ;;
    vless-grpc)
      local uuid=$(jq -r .uuid <<<"$b") sn=$(jq -r .grpc.service_name <<<"$inb")
      echo "vless://${uuid}@${ip}:${port}?encryption=none&security=tls&type=grpc&serviceName=${sn}#${tag}"
      ;;
    anytls)
      local pw=$(jq -r .password <<<"$b")
      echo "anytls://${pw}@${ip}:${port}?security=tls&sni=$(jq -r '.tls.sni // ""' <<<"$inb")#${tag}"
      ;;
    hysteria2)
      local pw=$(jq -r .password <<<"$b")
      local hop=$(jq -r '.hop_ports // ""' <<<"$inb"); [ "$hop" = null ] && hop=""
      local mport=$port; [ -n "$hop" ] && mport="$hop"
      echo "hy2://${pw}@${ip}:${mport}?insecure=1&sni=$(jq -r '.tls.sni // ""' <<<"$inb")#${tag}"
      ;;
    tuic)
      local uuid=$(jq -r .uuid <<<"$b") pw=$(jq -r .password <<<"$b")
      echo "tuic://${uuid}:${pw}@${ip}:${port}?congestion_control=$(jq -r '.congestion_control // "bbr"' <<<"$inb")&alpn=h3&sni=$(jq -r '.tls.sni // ""' <<<"$inb")#${tag}"
      ;;
    shadowsocks)
      local fp=$(jq -r '.full_password // ""' <<<"$b")
      local userinfo=$(printf '%s' "$(jq -r '.ss2022.method' <<<"$inb"):${fp}" | b64_oneline)
      echo "ss://${userinfo}@${ip}:${port}#${tag}"
      ;;
    vless-tcp)
      local uuid=$(jq -r .uuid <<<"$b")
      echo "vless://${uuid}@${ip}:${port}?encryption=none&security=none&type=tcp#${tag}"
      ;;
    socks)
      echo "socks5://$(jq -r .socks_user <<<"$b"):$(jq -r .socks_pass <<<"$b")@${ip}:${port}#${tag}"
      ;;
  esac
}

# 生成用户订阅文件并输出
gen_user_sub() { # <user_id>
  local uid=$1
  local u=$(jq -c --argjson i "$uid" '.[] | select(.id==$i)' "$SB_USERS")
  [ -z "$u" ] || [ "$u" = null ] && return 1
  local token=$(jq -r '.sub_token' <<<"$u")
  local links="" b inb
  _sb_tmp=$(mktemp)
  jq -c '.bindings[]?' <<<"$u" > "$_sb_tmp" 2>/dev/null
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    inb=$(jq -c --argjson i "$(jq -r .inbound_id <<<"$b")" '.[] | select(.id==$i)' "$SB_INBOUNDS")
    [ -n "$inb" ] && [ "$inb" != null ] && links+=$(gen_node_link "$u" "$b" "$inb")$'\n'
  done < "$_sb_tmp"
  rm -f "$_sb_tmp"
  if [ -n "$links" ]; then
    printf '%s' "$links" | b64_oneline > "$SB_SUBS_DIR/${token}.txt"
  else
    : > "$SB_SUBS_DIR/${token}.txt"
  fi
}

user_sub_menu() {
  user_list_simple || return
  local uid=$(ask "选择用户序号: ")
  local u=$(jq -c --argjson i "$uid" '.[] | select(.id==$i)' "$SB_USERS")
  [ -z "$u" ] || [ "$u" = null ] && { echo "不存在"; return; }
  local token=$(jq -r '.sub_token' <<<"$u")
  gen_user_sub "$uid"
  echo "===== 单节点链接 ====="
  local b inb
  _sb_tmp=$(mktemp)
  jq -c '.bindings[]?' <<<"$u" > "$_sb_tmp" 2>/dev/null
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    inb=$(jq -c --argjson i "$(jq -r .inbound_id <<<"$b")" '.[] | select(.id==$i)' "$SB_INBOUNDS")
    [ -n "$inb" ] && [ "$inb" != null ] && gen_node_link "$u" "$b" "$inb"
  done < "$_sb_tmp"
  rm -f "$_sb_tmp"
  echo
  echo "===== 聚合订阅（base64，复制即可用） ====="
  cat "$SB_SUBS_DIR/${token}.txt"; echo
  echo "（文件: $SB_SUBS_DIR/${token}.txt）"
}

user_menu() {
  while :; do
    echo "--- 用户列表 ---"; user_list_simple
    echo "1.添加用户  2.编辑用户  3.绑定入站  4.解绑入站  5.删除用户  6.用户订阅  0.返回"
    case $(ask "选择: ") in
      1) user_add ;;
      2) user_edit ;;
      3) user_bind ;;
      4) user_unbind ;;
      5) user_del ;;
      6) user_sub_menu ;;
      0) return ;;
    esac
  done
}
