# sb-mgr 部署指南（sing-box 多用户节点管理脚本 v1.0）

## 安装（VPS，root）

```bash
tar xzf sb-mgr-v1.0.tar.gz
cd sb-mgr
bash install.sh
```

安装器自动：装依赖（bash/jq/curl/openssl/tar/nftables）→ 部署脚本到 /opt/sb-mgr/scripts → 注册 `sb` 命令 → 初始化 /etc/sing-box-mgr → 下载 grpcurl。

## 使用流程

1. `sb` → 3.核心管理 → 1.安装核心
   - **选 (1) 官方最新版**：无按用户流量统计（流量列显示「未统计」）
   - **选 (4) 统计增强版**（Tangfffyx 编译，sha256 校验）：含 v2ray_api，支持按用户流量统计/到期/超额自动断开
2. 1.入站管理 → 添加入站（10 种协议；Reality 密钥自动生成，TLS 类需证书路径；hy2 支持端口跳跃）
3. 2.用户管理 → 添加用户（配额/到期/自然月重置日）→ 绑定入站（此时才生成凭证）→ 用户订阅（单链接 + base64 聚合订阅）
4. 出站管理：粘节点链接解析、连通性测试、出站绑定入站（共享出口）
5. 备份：base64 串复制保存；恢复粘贴即可

## 数据位置

- 状态：/etc/sing-box-mgr/data/*.json（重装不丢）
- 生成的运行配置：/etc/sing-box-mgr/config.json（自动 check，失败自动回滚）
- 订阅：/etc/sing-box-mgr/subs/<token>.txt
- 日志：/var/log/sb-mgr.log

## 文件结构

```
install.sh          一键安装
scripts/sb          主入口（/usr/local/bin/sb 软链）
scripts/sb-stats.sh 定时统计任务执行体
scripts/lib/
  common.sh    公共库（路径/JSON原子写/凭证生成/系统探测）
  genconfig.sh 渲染器（状态→config.json，check 后才 reload）
  inbound.sh   入站管理（10 协议模板）
  user.sh      用户/绑定/订阅
  stats.sh     流量统计（grpcurl 差值累计、月度重置、到期断开）
  core.sh      核心安装/更新/卸载、DNS、出站管理
  backup_ui.sh 备份恢复、主菜单
```

## 已验证（本地 Alpine + 官方 sing-box v1.12.0 真实 check）

- 10 协议渲染全部通过 `sing-box check`（Reality/hy2/TUIC/SS2022/socks/vless 系）
- 到期用户自动从 users 剔除；SS2022 主密钥+用户密钥分离（客户端用 `主密钥:用户密钥` 拼接值，见订阅链接）
- 流量差值累计、核心重启回落、自然月重置三场景
- 备份/恢复 base64 闭环；订阅链接生成；五类出站链接解析
- BusyBox 兼容（无 grep -P / base64 -w0 / 进程替换）

## 已知限制

- sing-box 无热重载，应用配置 = restart（会断连）
- 流量统计需要「统计增强版」核心（官方 release 无 v2ray_api 构建 tag）
- glibc 动态二进制：Alpine VPS 需确认兼容（musl 可装 libc-compat 或选自编译）；Debian 无碍
- 统计周期 5 分钟采样，进程异常退出时尾部流量无法恢复
