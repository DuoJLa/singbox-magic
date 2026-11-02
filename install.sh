#!/usr/bin/env bash
# install.sh —— sb-mgr 一键安装（部署到 VPS）
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "请以 root 运行"; exit 1; }

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
SB_ETC=/etc/sing-box-mgr
SB_SCRIPTS=/opt/sb-mgr/scripts
SB_BIN=/usr/local/bin

echo "== sb-mgr 安装 =="

# 1. 依赖
PKGS_BASH=(bash jq curl openssl tar)
if command -v apt >/dev/null 2>&1; then
  echo "Debian 系，安装依赖..."
  apt update -qq && apt install -y -qq "${PKGS_BASH[@]}" nftables >/dev/null
elif command -v apk >/dev/null 2>&1; then
  echo "Alpine，安装依赖..."
  apk add --no-cache "${PKGS_BASH[@]}" nftables >/dev/null
else
  echo "未识别系统，请自行安装: ${PKGS_BASH[*]}"
fi

# 2. 获取脚本源：本仓库（单文件安装时自动从 GitHub 拉取完整包）
REPO="DuoJLa/singbox-magic"
if [ -d "$SRC_DIR/scripts/lib" ]; then
  SRC="$SRC_DIR"   # 完整包安装（tar 解压后）
else
  echo "从 GitHub 拉取脚本..."
  DL=$(mktemp -d)
  if ! curl -fsLm 120 -o "$DL/repo.tar.gz" "https://github.com/${REPO}/archive/refs/heads/main.tar.gz"; then
    echo "下载失败，请检查网络或手动安装: git clone https://github.com/${REPO}.git"; exit 1
  fi
  tar xzf "$DL/repo.tar.gz" -C "$DL"
  SRC=$(find "$DL" -maxdepth 2 -name scripts -type d | head -1 | xargs dirname)
  [ -n "$SRC" ] || { echo "仓库结构异常"; exit 1; }
fi

# 3. 复制脚本
mkdir -p "$SB_ETC/data" "$SB_ETC/subs" "$SB_SCRIPTS/lib" "$SB_BIN/bin"
cp "$SRC/scripts/sb" "$SB_SCRIPTS/sb"
cp "$SRC/scripts/sb-stats.sh" "$SB_SCRIPTS/sb-stats.sh"
cp "$SRC"/scripts/lib/*.sh "$SB_SCRIPTS/lib/"
chmod +x "$SB_SCRIPTS"/sb*.sh

# 4. 注册 sb 命令
ln -sf "$SB_SCRIPTS/sb" "$SB_BIN/sb"

# 4. 初始化配置
[ -f "$SB_ETC/config.env" ] || cat > "$SB_ETC/config.env" <<EOF
SB_API_PORT=15490
SB_API_TOKEN="$(cat /proc/sys/kernel/random/uuid)"
SB_DNS="1.1.1.1,8.8.8.8"
SB_UPDATE_REPO="DuoJLa/singbox-magic"
SB_STATS_ENABLED=0
EOF
[ -f "$SB_ETC/data/users.json" ] || echo '[]' > "$SB_ETC/data/users.json"
[ -f "$SB_ETC/data/inbounds.json" ] || echo '[]' > "$SB_ETC/data/inbounds.json"
[ -f "$SB_ETC/data/outbounds.json" ] || echo '[]' > "$SB_ETC/data/outbounds.json"
[ -f "$SB_ETC/data/state.json" ] || echo '{}' > "$SB_ETC/data/state.json"

# 5. 下载 grpcurl（流量统计，静态二进制）
if [ ! -x "$SB_BIN/bin/grpcurl" ]; then
  echo "下载 grpcurl..."
  ARCH=amd64; [ "$(uname -m)" = aarch64 ] && ARCH=arm64
  curl -fsL "https://github.com/fullstorydev/grpcurl/releases/latest/download/grpcurl_1.9.3_linux_${ARCH}.tar.gz" \
    | tar xz -C /tmp grpcurl && mv /tmp/grpcurl "$SB_BIN/bin/grpcurl" && chmod +x "$SB_BIN/bin/grpcurl" \
    && echo "grpcurl 就绪" || echo "警告: grpcurl 下载失败，流量统计暂不可用（sb 内可重试安装）"
fi

echo
echo "安装完成！"
echo "  运行 sb        进入管理菜单"
echo "  核心安装       菜单 → 3.核心管理 → 1.安装/更新核心"
