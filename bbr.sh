#!/bin/bash

# =============================================================
# 脚本名称: BBR + BDP 综合加速工具 (核心修复版)
# =============================================================

if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行此脚本。"
   exit 1
fi

# 1. 环境准备与组件安装
install_deps() {
    if ! command -v bc >/dev/null 2>&1; then
        echo "正在安装必要组件 bc..."
        if command -v apt-get >/dev/null; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1
        elif command -v yum >/dev/null; then
            yum install -y bc >/dev/null 2>&1
        fi
    fi
}
install_deps

# --- 2. 状态看板：显示当前加速类型 ---
show_status() {
    local c_bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local c_qdisc=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    local c_rmem=$(sysctl net.core.rmem_max 2>/dev/null | awk '{print $3}')
    
    # 颜色标签逻辑
    local bbr_info="\033[31m未开启\033[0m"
    [[ "$c_bbr" == "bbr" ]] && bbr_info="\033[32mBBR 已生效\033[0m"
    
    local qdisc_info="\033[31m默认\033[0m"
    [[ "$c_qdisc" == "fq" ]] && qdisc_info="\033[32mFQ (极致跑速)\033[0m"
    [[ "$c_qdisc" == "cake" ]] && qdisc_info="\033[32mCAKE (防抖动/游戏)\033[0m"
    
    local rmem_mb=$(echo "$c_rmem / 1024 / 1024" | bc 2>/dev/null || echo "0")

    echo -e "-----------------------------------------------"
    echo -e "📊 \033[1m当前系统加速状态\033[0m"
    echo -e "   >> 拥塞控制 (TCP): $bbr_info"
    echo -e "   >> 队列算法 (QDisc): $qdisc_info"
    echo -e "   >> 最大缓存 (Buffer): ${rmem_mb} MB"
    echo -e "   >> 系统内核版本: $(uname -r)"
    echo -e "-----------------------------------------------"
}

# --- 3. 内核升级函数 ---
upgrade_kernel() {
    echo "正在尝试升级内核..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y linux-image-generic linux-headers-generic
    elif [ -f /etc/redhat-release ]; then
        rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
        local rv=$(rpm -E %rhel)
        yum install -y "https://www.elrepo.org/elrepo-release-${rv}.el${rv}.elrepo.noarch.rpm"
        yum --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-devel
        [[ -f /usr/sbin/grubby ]] && grubby --set-default=$(ls /boot/vmlinuz-*ml*)
    fi
    echo -e "\033[32m内核安装完成，请重启系统！\033[0m"
    read -p "是否立即重启? (y/n): " res && [[ "$res" == "y" ]] && reboot
}

# --- 4. 主流程 ---
clear
echo "==============================================="
echo "      TCP BDP 综合调优工具"
echo "==============================================="
show_status

echo "1) 🚀 应用/更新 加速配置"
echo "2) 🆙 升级系统内核"
echo "3) 🗑️  卸载加速配置"
read -p "请选择 [1-3, 默认1]: " OPT; OPT=${OPT:-1}

if [[ "$OPT" == "3" ]]; then
    rm -f /etc/sysctl.d/99-net-speedup.conf && sysctl --system
    echo "已恢复默认。" && exit 0
elif [[ "$OPT" == "2" ]]; then
    upgrade_kernel && exit 0
fi

# --- 5. 参数输入与修复版计算 ---
echo "-----------------------------------------------"
read -p "请输入服务器带宽 (Mbps, 默认 1000): " S_BW; S_BW=${S_BW:-1000}
read -p "请输入本地下行带宽 (Mbps, 默认 1000): " L_BW; L_BW=${L_BW:-1000}
read -p "请输入往返延迟 (ms, 默认 160): " RTT; RTT=${RTT:-160}

# 修复后的带宽比较逻辑 (使用 -lt 整数比较)
if [ "$S_BW" -lt "$L_BW" ]; then
    FINAL_BW=$S_BW
else
    FINAL_BW=$L_BW
fi

# 计算 3 倍 BDP 缓存 (单线程优化核心)
BDP=$(echo "$FINAL_BW * $RTT * 125 * 3" | bc 2>/dev/null)
BDP=${BDP:-67108864}

# 边界值锁定
[ "$BDP" -lt 16777216 ] && BDP=16777216
[ "$BDP" -gt 536870912 ] && BDP=536870912
MAX_BUF_MB=$(echo "$BDP / 1024 / 1024" | bc)

# 6. 算法兼容性识别
kernel_ver=$(uname -r | cut -d- -f1 | awk -F. '{print $1"."$2}')
can_cake=$(echo "$kernel_ver >= 4.19" | bc 2>/dev/null)
can_cake=${can_cake:-0}

echo "-----------------------------------------------"
echo "选择 QDisc 算法:"
echo "1) FQ (极致单线程跑速)"
if [[ "$can_cake" == "1" ]]; then
    echo "2) CAKE (低延迟游戏优化)"
else
    echo "x) CAKE (内核版本过低不支持)"
fi
read -p "请选择 [1-2, 默认1]: " Q_OPT; Q_OPT=${Q_OPT:-1}
[[ "$Q_OPT" == "2" && "$can_cake" == "1" ]] && SEL_Q="cake" || SEL_Q="fq"

# 7. 应用配置并尝试加载模块
modprobe tcp_bbr 2>/dev/null
modprobe sch_$SEL_Q 2>/dev/null

cat > /etc/sysctl.d/99-net-speedup.conf << EOF
net.core.default_qdisc = $SEL_Q
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

sysctl --system > /dev/null
echo -e "\033[32m✅ 加速配置已应用！\033[0m"
show_status
