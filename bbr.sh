#!/bin/bash

# =============================================================
# 脚本名称: BBR + BDP + 内核自动升级工具 (终极整合版)
# 支持系统: Debian, Ubuntu, CentOS, AlmaLinux, Rocky Linux
# =============================================================

if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行此脚本。"
   exit 1
fi

# 1. 基础组件安装
install_deps() {
    echo "正在检查并安装必要组件..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y >/dev/null 2>&1 && apt-get install -y bc curl wget >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bc curl wget >/dev/null 2>&1
    fi
}
install_deps

# --- 函数：升级内核 ---
upgrade_kernel() {
    echo "-----------------------------------------------"
    echo "正在准备升级内核..."
    
    if [ -f /etc/debian_version ]; then
        # Debian/Ubuntu 升级
        echo "检测到 Debian/Ubuntu 系统，正在安装最新内核..."
        apt-get update -y
        apt-get install -y linux-image-generic linux-headers-generic
    elif [ -f /etc/redhat-release ]; then
        # CentOS/RHEL/Alma/Rocky 升级
        echo "检测到 RHEL 系系统，正在通过 ELRepo 安装最新内核..."
        rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
        local rel_ver=$(rpm -E %rhel)
        if [ "$rel_ver" == "7" ]; then
            yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm
        else
            yum install -y "https://www.elrepo.org/elrepo-release-${rel_ver}.el${rel_ver}.elrepo.noarch.rpm"
        fi
        yum --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-devel
        # 设置 grub 默认启动最新内核
        if command -v grub2-set-default >/dev/null; then
            grub2-set-default 0
        fi
    else
        echo "错误: 未知系统，请手动升级内核。"
        return 1
    fi

    echo "-----------------------------------------------"
    echo "✅ 内核安装完成！必须重启系统后才能应用加速。"
    read -p "是否现在重启系统？(y/n): " CONFIRM_REBOOT
    if [[ "$CONFIRM_REBOOT" == "y" || "$CONFIRM_REBOOT" == "Y" ]]; then
        reboot
    else
        echo "请稍后手动重启，重启前加速配置不会完全生效。"
        exit 0
    fi
}

# --- 2. 主程序开始 ---
clear
echo "==============================================="
echo "      TCP 综合调优 + 内核升级工具"
echo "==============================================="

# 检查当前内核
kernel_ver=$(uname -r | cut -d- -f1 | awk -F. '{print $1"."$2}')
can_bbr=$(echo "$kernel_ver >= 4.9" | bc 2>/dev/null)
can_cake=$(echo "$kernel_ver >= 4.19" | bc 2>/dev/null)

echo "当前内核版本: $(uname -r)"
if [[ "$can_bbr" != "1" ]]; then
    echo "❌ 警告: 当前内核不支持 BBR (需 4.9+)"
elif [[ "$can_cake" != "1" ]]; then
    echo "⚠️ 提醒: 当前内核不支持 CAKE (需 4.19+)，仅能开启 FQ"
else
    echo "✅ 当前内核支持所有加速选项"
fi

echo "-----------------------------------------------"
echo "1) 升级内核"
echo "2) 应用/更新 TCP 加速配置 (BBR + BDP)"
echo "3) 卸载加速配置"
read -p "请选择 [1-3, 默认2]: " MAIN_CHOICE
MAIN_CHOICE=${MAIN_CHOICE:-2}

case $MAIN_CHOICE in
    1)
        upgrade_kernel
        ;;
    3)
        rm -f /etc/sysctl.d/99-net-speedup.conf
        sysctl --system
        echo "已恢复默认配置。"
        exit 0
        ;;
    *)
        # 继续执行加速配置逻辑
        ;;
esac

# 3. 手动参数输入
echo "-----------------------------------------------"
read -p "1. 服务器带宽 (Mbps, 默认 1000): " SRV_BW; SRV_BW=${SRV_BW:-1000}
read -p "2. 本地下载带宽 (Mbps, 默认 1000): " LOCAL_BW; LOCAL_BW=${LOCAL_BW:-1000}
read -p "3. 往返延迟 (ms, 默认 160): " LATENCY; LATENCY=${LATENCY:-160}

# 计算瓶颈带宽并计算 3 倍 BDP 缓存
if [ "$SRV_BW" -lt "$LOCAL_BW" ]; then FINAL_BW=$SRV_BW; else FINAL_BW=$LOCAL_BW; fi
BDP=$(echo "$FINAL_BW * $LATENCY * 125 * 3" | bc 2>/dev/null)
BDP=${BDP:-67108864}

[ "$BDP" -lt 16777216 ] && BDP=16777216
[ "$BDP" -gt 536870912 ] && BDP=536870912
MAX_BUF_MB=$(echo "$BDP / 1024 / 1024" | bc)

# 4. 算法选择
echo "-----------------------------------------------"
echo "选择调度算法 (QDisc):"
echo "1) FQ   (单线程极限速度)"
if [[ "$can_cake" == "1" ]]; then
    echo "2) CAKE (延迟平滑优化)"
else
    echo "x) CAKE (当前内核不支持，请选 1 或先升级内核)"
fi
read -p "选择 [1-2, 默认1]: " QCHOICE; QCHOICE=${QCHOICE:-1}
[[ "$QCHOICE" == "2" && "$can_cake" == "1" ]] && SELECTED_QDISC="cake" || SELECTED_QDISC="fq"

# 5. 模块尝试加载与写入配置
modprobe tcp_bbr >/dev/null 2>&1
modprobe sch_fq >/dev/null 2>&1

cat > /etc/sysctl.d/99-net-speedup.conf << EOF
net.core.default_qdisc = $SELECTED_QDISC
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $BDP
net.core.wmem_max = $BDP
net.ipv4.tcp_rmem = 4096 131072 $BDP
net.ipv4.tcp_wmem = 4096 131072 $BDP
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_reordering = 10
net.ipv4.tcp_sack = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_notsent_lowat = 16384
EOF

sysctl --system
echo "-----------------------------------------------"
echo "✅ 调优配置已尝试应用！"
echo ">> 当前内核状态提示：如果上方仍报错，请运行脚本并选 1 升级内核。"
echo "==============================================="
