#!/usr/bin/env bash
# backup.sh —— 备份/恢复（base64）；ui.sh —— 主菜单
set -u
. /opt/sb-mgr/scripts/lib/common.sh

ask() { local ans; read -rp "${1:-}" ans; echo "$ans"; }

do_backup() {
  sb_init_data
  # 写入版本标识后打包
  jq -n --arg v "$SB_PLAN_VERSION" '{plan_version:$v, date:(now | todate)}' > "$SB_DATA/.backup_meta"
  echo "===== 备份（复制以下 base64 串保存） ====="
  tar cz -C "$SB_ETC" data config.env 2>/dev/null | b64_oneline
  echo; echo "=========================================="
  rm -f "$SB_DATA/.backup_meta"
  sb_log "backup generated"
}

do_restore() {
  echo "粘贴备份 base64 串:"
  local b64=$(ask "> ")
  [ -z "$b64" ] && return
  local tmp=$(mktemp -d)
  if ! printf '%s' "$b64" | base64 -d 2>/dev/null | tar xz -C "$tmp" 2>/dev/null; then
    echo "恢复失败: base64 或 tar 数据损坏"; rm -rf "$tmp"; return 1
  fi
  # 校验版本与 JSON 合法性
  local pv=$(jq -r '.plan_version // 0' "$tmp/data/.backup_meta" 2>/dev/null)
  [ "$pv" != "$SB_PLAN_VERSION" ] && echo "警告: 备份版本 v$pv 与当前 v$SB_PLAN_VERSION 不一致，仍尝试恢复"
  for f in users.json inbounds.json outbounds.json; do
    if [ -f "$tmp/data/$f" ] && ! jq empty "$tmp/data/$f" 2>/dev/null; then
      echo "恢复失败: $f 校验不合法"; rm -rf "$tmp"; return 1
    fi
  done
  echo "将覆盖现有全部数据，确认? [y/N]"
  [ "$(ask)" = "y" ] || { rm -rf "$tmp"; echo 已取消; return; }
  mkdir -p "$SB_ETC"
  cp "$tmp/data/"*.json "$SB_DATA/"
  [ -f "$tmp/config.env" ] && cp "$tmp/config.env" "$SB_ETC/"
  rm -rf "$tmp"
  sb_log "restored from backup"
  echo "已恢复。是否立即应用配置? [Y/n]"
  [ "$(ask)" != "n" ] && apply_config
}

# ============ 主界面 ============
banner() {
  clear 2>/dev/null || true
  echo "╔══════════════════════════════════════╗"
  echo "║   sing-box 多用户节点管理  v$SB_VERSION      ║"
  echo "╚══════════════════════════════════════╝"
  echo "系统: $(detect_os) ｜ 模式: $(detect_init)"
  echo "核心: $(core_status)"
  echo "----- 用户统计 -----"
  user_list_full
  echo "──────────────────────────────────────"
}

main_menu() {
  while :; do
    banner
    echo " 1.入站管理   2.用户管理   3.核心管理"
    echo " 4.出站管理   5.备份与恢复 6.更新控制脚本"
    echo " 0.退出"
    case $(ask "选择: ") in
      1) inbound_menu ;;
      2) user_menu ;;
      3) core_menu ;;
      4) outbound_menu ;;
      5) backup_menu ;;
      6) update_self ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

backup_menu() {
  echo "1.备份  2.恢复  0.返回"
  case $(ask "选择: ") in
    1) do_backup ;;
    2) do_restore ;;
    0) return ;;
  esac
}

update_self() {
  . "$SB_ETC/config.env" 2>/dev/null
  local repo=${SB_UPDATE_REPO:-}
  if [ -z "$repo" ]; then
    echo "未配置更新仓库（$SB_ETC/config.env 中 SB_UPDATE_REPO）。"
    local r=$(ask "输入 GitHub 仓库 (owner/repo)，留空跳过: ")
    [ -z "$r" ] && return
    set_config_env SB_UPDATE_REPO "$r"; repo=$r
  fi
  echo "从 $repo 拉取最新脚本..."
  local tmp=$(mktemp -d)
  if curl -fsLm 120 -o "$tmp/repo.tar.gz" "https://github.com/${repo}/archive/refs/heads/main.tar.gz"; then
    tar xzf "$tmp/repo.tar.gz" -C "$tmp"
    local src=$(find "$tmp" -maxdepth 3 -path '*/scripts/lib' -type d | head -1 | xargs dirname)
    if [ -n "$src" ] && [ -d "$src/lib" ]; then
      cp "$src"/sb "$src"/sb-stats.sh "$SB_SCRIPTS"/
      cp "$src"/lib/*.sh "$SB_SCRIPTS/lib/"
      sb_log "scripts updated from $repo"
      echo "已更新。重启 sb 生效。"
    else
      echo "仓库结构不符，未更新"
    fi
  else
    echo "下载失败，请检查仓库地址或网络"
  fi
  rm -rf "$tmp"
}
