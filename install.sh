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

# 2. 复制脚本
mkdir -p "$SB_ETC/data" "$SB_ETC/subs" "$SB_SCRIPTS/lib" "$SB_BIN/bin"
cp "$SRC_DIR/sb" "$SB_SCRIPTS/sb"
cp "$SRC_DIR/sb-stats.sh" "$SB_SCRIPTS/sb-stats.sh"
cp "$SRC_DIR"/lib/*.sh "$SB_SCRIPTS/lib/"
chmod +x "$SB_SCRIPTS"/sb*.sh

# 3. 注册 sb 命令
ln -sf "$SB_SCRIPTS/sb" "$SB_BIN/sb"

# 4. 初始化配置
[ -f "$SB_ETC/config.env" ] || cat > "$SB_ETC/config.env" <<EOF
SB_API_PORT=15490
SB_API_TOKEN="$(cat /proc/sys/kernel/random/uuid)"
SB_DNS="1.1.1.1,8.8.8.8"
SB_UPDATE_REPO=""
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
