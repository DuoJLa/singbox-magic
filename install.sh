#!/usr/bin/env bash
# install.sh —— sb-mgr 一键安装（部署到 VPS）
# 版本标记，用于 CDN 缓存自检
INSTALLER_VERSION="20251103"

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "请以 root 运行"; exit 1; }

# ── CDN 缓存自检（若 wget 命中旧缓存，此处会因缺少版本标记而失败提示） ──
if [ "${INSTALLER_VERSION:-0}" -lt "20251103" ] 2>/dev/null; then
  echo "错误: 此 install.sh 版本过旧（可能命中 CDN 缓存）。"
  echo "请改用: curl -fsSL 'https://raw.githubusercontent.com/DuoJLa/singbox-magic/main/install.sh' -o install.sh && bash install.sh"
  exit 1
fi

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
SB_ETC=/etc/sing-box-mgr
SB_SCRIPTS=/opt/sb-mgr/scripts
SB_TOOLS=/opt/sb-mgr/bin        # 辅助工具目录（grpcurl 等）
SB_BIN=/usr/local/bin            # $PATH 中的符号链接目录

echo "== sb-mgr 安装 (v${INSTALLER_VERSION}) =="

# ── 临时目录清理 trap ──
_CLEANUP_DIRS=""
cleanup() { [ -n "$_CLEANUP_DIRS" ] && rm -rf $_CLEANUP_DIRS 2>/dev/null || true; }
trap cleanup EXIT

# ── 1. 依赖 ──
PKGS=(bash jq curl openssl tar)
if command -v apt >/dev/null 2>&1; then
  echo "Debian 系，安装依赖..."
  apt update -qq && apt install -y -qq "${PKGS[@]}" nftables >/dev/null
elif command -v apk >/dev/null 2>&1; then
  echo "Alpine，安装依赖..."
  apk add --no-cache "${PKGS[@]}" nftables >/dev/null
else
  echo "未识别系统，请自行安装: ${PKGS[*]} nftables"
fi

# 验证关键命令
for cmd in bash jq curl tar; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "错误: 依赖 $cmd 安装失败，请手动安装后重试"; exit 1; }
done

# ── 2. 获取脚本源 ──
REPO="DuoJLa/singbox-magic"

if [ -d "$SRC_DIR/scripts/lib" ]; then
  SRC="$SRC_DIR"   # 完整仓库（git clone 或 tar 解压后）
else
  echo "从 GitHub 拉取脚本..."
  DL=$(mktemp -d)
  _CLEANUP_DIRS="$DL"

  if ! curl -fsSLm 120 -o "$DL/repo.tar.gz" \
       "https://github.com/${REPO}/archive/refs/heads/main.tar.gz"; then
    echo "下载失败，请检查网络或手动安装:"
    echo "  git clone https://github.com/${REPO}.git && cd singbox-magic && bash install.sh"
    exit 1
  fi

  tar xzf "$DL/repo.tar.gz" -C "$DL"

  # 安全查找：find -print0 写入临时列表（本沙箱无 /dev/fd，VPS 正常，但临时文件法两者都稳）
  SRC=""
  _find_list=$(mktemp)
  find "$DL" -maxdepth 2 -name scripts -type d -print0 2>/dev/null > "$_find_list" || true
  while IFS= read -r -d '' dir; do
    SRC=$(dirname "$dir")
    break
  done < "$_find_list"
  rm -f "$_find_list"

  if [ -z "$SRC" ] || [ ! -d "$SRC/scripts/lib" ]; then
    echo "仓库结构异常（未找到 scripts/lib 目录）"
    exit 1
  fi
fi

# 旧版本兼容：迁移误放的 grpcurl
[ -x /usr/local/bin/bin/grpcurl ] && mv /usr/local/bin/bin/grpcurl "$SB_TOOLS/grpcurl" 2>/dev/null || true

# ── 3. 复制脚本 ──
mkdir -p "$SB_ETC/data" "$SB_ETC/subs" "$SB_SCRIPTS/lib" "$SB_TOOLS"

cp "$SRC/scripts/sb"          "$SB_SCRIPTS/sb"
cp "$SRC/scripts/sb-stats.sh" "$SB_SCRIPTS/sb-stats.sh"

# 安全复制 lib/*.sh（处理空目录边界）
shopt -s nullglob
_lib_files=("$SRC"/scripts/lib/*.sh)
shopt -u nullglob
if [ ${#_lib_files[@]} -eq 0 ]; then
  echo "错误: scripts/lib/ 下未找到 .sh 文件，仓库可能不完整"
  exit 1
fi
cp "${_lib_files[@]}" "$SB_SCRIPTS/lib/"

chmod +x "$SB_SCRIPTS/sb" "$SB_SCRIPTS/sb-stats.sh"

# ── 4. 注册 sb 命令 ──
ln -sf "$SB_SCRIPTS/sb" "$SB_BIN/sb"

# ── 5. 初始化配置 ──
_gen_token() {
  if [ -f /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    tr -dc 'a-f0-9' </dev/urandom | head -c 32
  fi
}

if [ ! -f "$SB_ETC/config.env" ]; then
  _token=$(_gen_token)
  cat > "$SB_ETC/config.env" <<EOF
SB_API_PORT=15490
SB_API_TOKEN="${_token}"
SB_DNS="1.1.1.1,8.8.8.8"
SB_UPDATE_REPO="${REPO}"
SB_STATS_ENABLED=0
EOF
fi

[ -f "$SB_ETC/data/users.json" ]     || echo '[]' > "$SB_ETC/data/users.json"
[ -f "$SB_ETC/data/inbounds.json" ]  || echo '[]' > "$SB_ETC/data/inbounds.json"
[ -f "$SB_ETC/data/outbounds.json" ] || echo '[]' > "$SB_ETC/data/outbounds.json"
[ -f "$SB_ETC/data/state.json" ]     || echo '{}' > "$SB_ETC/data/state.json"

# ── 6. 下载 grpcurl（流量统计用，可选，失败不阻断） ──
if [ ! -x "$SB_TOOLS/grpcurl" ]; then
  echo "下载 grpcurl..."
  ARCH=amd64
  [ "$(uname -m)" = "aarch64" ] && ARCH=arm64

  # 1.9.3 tar.gz（注意架构名: x86_64/arm64，非 amd64）；子 shell 封装防 set -e 中途退出
  GARCH=x86_64
  [ "$ARCH" = arm64 ] && GARCH=arm64
  if (
    set -e
    curl -fsSLm 120 \
      "https://github.com/fullstorydev/grpcurl/releases/download/v1.9.3/grpcurl_1.9.3_linux_${GARCH}.tar.gz" \
      | tar xz -C /tmp grpcurl
    mv /tmp/grpcurl "$SB_TOOLS/grpcurl"
    chmod +x "$SB_TOOLS/grpcurl"
  ); then
    echo "  grpcurl 就绪"
  else
    echo "  警告: grpcurl 下载失败，流量统计暂不可用（安装核心选「统计增强版」后可重装）"
  fi
fi

# ── 7. 安装后自检 ──
_ok=true
for f in "$SB_SCRIPTS/sb" "$SB_SCRIPTS/sb-stats.sh" "$SB_ETC/config.env"; do
  [ -f "$f" ] || { echo "错误: $f 未正确安装"; _ok=false; }
done
[ -x "$SB_BIN/sb" ] || { echo "错误: sb 命令链接失败"; _ok=false; }
if [ "$_ok" != true ]; then
  echo "安装未完成，请检查以上错误。"
  exit 1
fi

echo
echo "安装完成！ (v${INSTALLER_VERSION})"
echo "  运行 sb        进入管理菜单"
echo "  核心安装       菜单 → 3.核心管理 → 1.安装/更新核心"
