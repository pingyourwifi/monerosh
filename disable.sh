#!/bin/bash

# 确保以root权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请以root权限运行此脚本（使用sudo）"
  exit 1
fi

echo "开始删除非原有的服务并禁用日志生成..."

# 删除非原有服务
echo "停止并删除 iscsi.service..."
systemctl stop iscsi.service
systemctl disable iscsi.service
rm -f /etc/systemd/system/iscsi.service

echo "停止并删除 rpcbind.service..."
systemctl stop rpcbind.service
systemctl disable rpcbind.service
rm -f /etc/systemd/system/rpcbind.service

echo "停止并删除 vmtoolsd.service..."
systemctl stop vmtoolsd.service
systemctl disable vmtoolsd.service
systemctl stop qemu-guest-agent.service
rm -f /etc/systemd/system/vmtoolsd.service

echo "停止并删除 starlight-agent.service..."
systemctl stop starlight-agent.service
systemctl disable starlight-agent.service
rm -f /etc/systemd/system/starlight-agent.service
rm -rf /etc/systemd/system/starlight-agent.service.d

echo "删除依赖目录..."
rm -rf /etc/systemd/system/cloud-final.service.wants
rm -rf /etc/systemd/system/cloud-init.target.wants
rm -rf /etc/systemd/system/mdmonitor.service.wants
rm -rf /etc/systemd/system/open-vm-tools.service.requires

echo "重新加载systemd配置..."
systemctl daemon-reload

# 禁用日志生成
echo "停止并禁用rsyslog..."
systemctl stop rsyslog
systemctl disable rsyslog

echo "配置systemd-journald禁用日志存储..."
sed -i 's/#Storage=auto/Storage=none/' /etc/systemd/journald.conf
systemctl restart systemd-journald

# 删除脚本自身
rm -- "$0"
echo "操作完成！非原有服务已删除，日志生成已禁用。"
