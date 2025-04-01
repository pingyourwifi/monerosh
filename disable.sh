#!/bin/bash

# 确保以root权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以root权限运行此脚本（使用sudo）"
  exit 1
fi

echo "开始执行清理操作..."

# 1. 删除非原有服务
echo "删除非原有服务..."

# iscsi.service
echo "停止并删除 iscsi.service..."
systemctl stop iscsi.service 2>/dev/null
systemctl disable iscsi.service 2>/dev/null
rm -f /etc/systemd/system/iscsi.service

# rpcbind.service
echo "停止并删除 rpcbind.service..."
systemctl stop rpcbind.service 2>/dev/null
systemctl disable rpcbind.service 2>/dev/null
rm -f /etc/systemd/system/rpcbind.service

# vmtoolsd.service
echo "停止并删除 vmtoolsd.service..."
systemctl stop vmtoolsd.service 2>/dev/null
systemctl disable vmtoolsd.service 2>/dev/null
rm -f /etc/systemd/system/vmtoolsd.service
rm -rf /etc/systemd/system/open-vm-tools.service.requires

# starlight-agent.service
echo "停止并删除 starlight-agent.service..."
systemctl stop starlight-agent.service 2>/dev/null
systemctl disable starlight-agent.service 2>/dev/null
rm -f /etc/systemd/system/starlight-agent.service
rm -rf /etc/systemd/system/starlight-agent.service.d

# 删除依赖目录
echo "删除依赖目录..."
rm -rf /etc/systemd/system/cloud-final.service.wants
rm -rf /etc/systemd/system/cloud-init.target.wants
rm -rf /etc/systemd/system/mdmonitor.service.wants

# 2. 删除可疑监控程序
echo "删除可疑监控程序..."

# qemu-guest-agent.service
echo "停止并删除 qemu-guest-agent.service..."
systemctl stop qemu-guest-agent.service 2>/dev/null
systemctl disable qemu-guest-agent.service 2>/dev/null
rm -f /etc/systemd/system/qemu-guest-agent.service
rm -f /lib/systemd/system/qemu-guest-agent.service
rm -f /usr/bin/qemu-ga
apt purge qemu-guest-agent -y 2>/dev/null
apt autoremove -y 2>/dev/null

# multipathd.service（可选，注释掉以保留，若需删除则取消注释）
# echo "停止并删除 multipathd.service..."
# systemctl stop multipathd.service 2>/dev/null
# systemctl disable multipathd.service 2>/dev/null
# rm -f /etc/systemd/system/multipathd.service
# rm -f /lib/systemd/system/multipathd.service
# apt purge multipath-tools -y 2>/dev/null

# ModemManager.service（可选，注释掉以保留，若需删除则取消注释）
# echo "停止并删除 ModemManager.service..."
# systemctl stop ModemManager.service 2>/dev/null
# systemctl disable ModemManager.service 2>/dev/null
# rm -f /etc/systemd/system/ModemManager.service
# rm -f /lib/systemd/system/ModemManager.service
# apt purge modemmanager -y 2>/dev/null

# 3. 禁用日志生成
echo "禁用系统日志生成..."

# 停止并禁用 rsyslog.service 和 syslog.socket
echo "停止并禁用 rsyslog 和 syslog.socket..."
systemctl stop rsyslog.service 2>/dev/null
systemctl stop syslog.socket 2>/dev/null
systemctl disable rsyslog.service 2>/dev/null
systemctl disable syslog.socket 2>/dev/null
# 可选：屏蔽服务和 socket
systemctl mask rsyslog.service 2>/dev/null
systemctl mask syslog.socket 2>/dev/null

# 配置 systemd-journald 禁用日志存储
echo "配置 systemd-journald 禁用日志..."
sed -i 's/#Storage=auto/Storage=none/' /etc/systemd/journald.conf
systemctl restart systemd-journald 2>/dev/null

# 4. 重新加载 systemd 配置
echo "重新加载 systemd 配置..."
systemctl daemon-reload

# 5. 验证删除结果
echo "验证删除结果..."
for service in iscsi.service rpcbind.service vmtoolsd.service starlight-agent.service qemu-guest-agent.service rsyslog.service syslog.socket; do
  if systemctl status "$service" >/dev/null 2>&1; then
    echo "警告：$service 仍存在，请检查！"
  else
    echo "$service 已删除或不存在。"
  fi
done

# 删除脚本自身
rm -- "$0"
echo "清理完成！请检查系统状态并重启以确认（sudo reboot）。"
