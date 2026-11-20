# Hysteria2 一键安装脚本 (hy2.sh)

基于 **sing-box** 的 Hysteria2 (UDP/QUIC) 一键安装脚本，专为 VPS 游戏加速 / 科学上网场景设计，内置网络栈深度调优、端口跳跃与 SWAP 管理。

## 快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zsl670324/hy2/main/hy2.sh)
```

国内 VPS 直连 GitHub 失败时，可走加速镜像：

```bash
bash <(curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/zsl670324/hy2/main/hy2.sh)
```

或手动下载执行：

```bash
wget -O hy2.sh https://raw.githubusercontent.com/zsl670324/hy2/main/hy2.sh
chmod +x hy2.sh
./hy2.sh
```

## 功能特性

- **一键部署** Hysteria2 服务端（sing-box 内核），交互式配置端口 / 密码 / 混淆 / SNI
- **证书二选一**：Let's Encrypt 自动签发（DNS 预检 + 80 端口占用自动处理），失败自动回退自签名证书
- **端口跳跃 (Port Hopping)**：iptables DNAT 将 UDP 端口段（默认 20000-50000）重定向到主端口，抗 UDP QoS / 封锁；systemd 开机自动应用；客户端 URI 自动附带 `mport` 参数
- **BBR + UDP/QUIC 深度调优**：64MB UDP 收发缓冲、分片重组队列、软中断预算、独立 sysctl 配置文件（重复运行不产生重复项）
- **网卡优化**：自动拉满 Ring Buffer、开启 GRO/GSO 卸载，开机自动应用
- **SWAP 管理**：内存 ≤ 1G 自动创建物理内存 2 倍的 SWAP；> 1G 时询问用户自选大小；fstab 持久化、幂等可重跑
- **伪装网站**：使用域名时自动部署 nginx 伪装站点（CDN 风格页面）
- **客户端配置**：自动生成连接 URI + 二维码 + sing-box 客户端配置（TUN MTU 1400）
- **管理命令**：安装完成后输入 `hy2` 进入管理菜单

## 交互流程

脚本为交互式，依次询问（直接回车即用默认值）：

1. Hysteria2 监听端口（默认 443）
2. 端口跳跃开关及端口段（默认 20000-50000）
3. 认证密码（默认随机生成）
4. Salamander 混淆密码（默认随机生成）
5. 伪装域名 / SNI（默认 www.cloudflare.com）
6. 是否拥有域名并申请 Let's Encrypt 证书
7. （内存 > 1G 时）是否创建 SWAP

## 管理命令

| 命令 | 说明 |
|---|---|
| `hy2` | 打开管理菜单 |
| `hy2 start / stop / restart` | 启停 / 重启服务 |
| `hy2 status` | 查看服务状态 |
| `hy2 log` | 查看最近日志 |
| `hy2 uri` | 查看客户端连接 URI |
| `hy2 qr` | 显示二维码 |
| `hy2 uninstall` | 彻底卸载 |

卸载也可运行：`./hy2.sh --uninstall`

## 注意事项

- 需 **root** 权限运行
- **云厂商控制台防火墙**需放行主端口 UDP 及端口跳跃段 `20000-50000/UDP`（脚本会配置系统防火墙，但管不到云安全组）
- 使用自签名证书时，客户端需开启「允许不安全」/ `insecure=1`
- sing-box 客户端不支持端口跳跃（走主端口）；官方 Hysteria2 客户端 / v2rayN 等识别 `mport` 后自动换端口
- 卸载不会删除 SWAP（系统级配置，如需删除请手动执行 `swapoff /swapfile && rm -f /swapfile` 并清理 /etc/fstab）

## 声明

本项目仅供学习交流与网络调试使用，请遵守所在地区法律法规。
