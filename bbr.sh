#!/bin/bash

# =============================================================
# 脚本名称: BBR + BDP 综合加速 (状态感知版)
# 功能：内核升级、参数自定义、单线程优化、实时状态查询
# =============================================================

if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行此脚本。"
   exit 1
fi

# 1. 环境准备
install_deps() {
    if ! command -v bc >/dev/null 2>&1; then
        if command -v apt-get >/dev/null; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1
        elif command -v yum >/dev/null; then
            yum install -y bc >/dev/null 2>&1
        fi
    fi
}
install_deps

# --- 2. 核心显示模块：检测当前加速类型 ---
show_status() {
    # 获取内核参数
    local c_bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local c_qdisc=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    local c_rmem=$(sysctl net.core.rmem_max 2>/dev/null | awk '{print $3}')
    
    # 逻辑判断显示标签
    local bbr_label="\033[31m未开启\033[0m"
    [[ "$c_bbr" == "bbr" ]] && bbr_label="\033[32mBBR 加速中 (已生效)\033[0m"
    
    local qdisc_label="\033[31m默认/未知\033[0m"
    [[ "$c_qdisc" == "fq" ]] && qdisc_label="\033[32mFQ (单线程强力型)\033[0m"
    [[ "$c_qdisc" == "cake" ]] && qdisc_label="\033[32mCAKE (综合平滑型)\033[0m"
    
    local rmem_mb=$(echo "$c_rmem / 1024 / 1024" | bc 2>/dev/null || echo "0")

    echo -e "-----------------------------------------------"
    echo -e "📊 \033[1m当前网络加速看板\033[0m"
    echo -e "   >> 拥塞控制算法 : $bbr_label"
    echo -e "   >> 队列调度算法 : $qdisc_label"
    echo -e "   >> TCP 最大缓存 : ${rmem_mb} MB"
    echo -e "   >> 系统内核版本 : $(uname -r)"
    echo -e "-----------------------------------------------"
}

# --- 3. 内核升级逻辑 ---
upgrade_kernel() {
    echo "正在检测系统发行版并准备升级内核..."
    if [ -f /etc/debian_version ]; then
        apt-get update && apt-get install -y linux-image-generic linux-headers-generic
    elif [ -f /etc/redhat-release ]; then
        rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
        local rv=$(rpm -E %rhel)
        yum install -y "https://www.elrepo.org/elrepo-release-${rv}.el${rv}.elrepo.noarch.rpm"
        yum --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-devel
        [[ -f /usr/sbin/grubby ]] && grubby --set-default=$(ls /boot/vmlinuz-*ml*)
    fi
    echo -e "\033[32m内核安装完毕，请重启系统！\033[0m"
    read -p "是否立即重启? (y/n): " res && [[ "$res" == "y" ]] && reboot
}

# --- 4. 主菜单 ---
clear
echo "==============================================="
echo "      TCP BDP 综合调优工具 (2026 增强版)"
echo "==============================================="
show_status

echo "1) 🚀 应用/更新 加速配置 (单线程强化)"
echo "2) 🆙 升级系统内核"
echo "3) 🗑️  卸载加速并恢复默认"
read -p "请选择 [1-3, 默认1]: " OPT; OPT=${OPT:-1}

if [[ "$OPT" == "3" ]]; then
    rm -f /etc/sysctl.d/99-net-speedup.conf && sysctl --system
    echo "已恢复默认。" && exit 0
elif [[ "$OPT" == "2" ]]; then
    upgrade_kernel && exit 0
fi

# --- 5. 参数定制与计算 ---
echo "-----------------------------------------------"
read -p "请输入服务器带宽 (Mbps, 默认 1000): " S_BW; S_BW=${S_BW:-1000}
read -p "请输入本地下行带宽 (Mbps, 默认 1000): " L_BW; L_BW=${L_BW:-1000}
read -p "请输入往返延迟 (ms, 默认 160): " RTT; RTT=${RTT:-160}

# 计算 3 倍 BDP 缓存 (单线程突破 200M 的关键)
FINAL_BW=$(([ $S_BW < $L_BW ] && echo $S_BW) || echo $L_BW)
BDP=$(echo "$FINAL_BW * $RTT * 125 * 3" | bc 2>/dev/null)
BDP=${BDP:-67108864}
[[ $BDP -lt 16777216 ]] && BDP=16777216
[[ $BDP -gt 536870912 ]] && BDP=536870912

# 6. 算法兼容性检查
k_major=$(uname -r | cut -d. -f1); k_minor=$(uname -r | cut -d. -f2)
can_cake=0; [[ $k_major -gt 4 || ($k_major -eq 4 && $k_minor -ge 19) ]] && can_cake=1

echo "-----------------------------------------------"
echo "选择 QDisc 算法:"
echo "1) FQ (单线程测速极佳)"
[[ $can_cake -eq 1 ]] && echo "2) CAKE (抗丢包与游戏优化)" || echo "x) CAKE (需内核 4.19+)"
read -p "请选择 [1-2, 默认1]: " Q_OPT; Q_OPT=${Q_OPT:-1}
[[ "$Q_OPT" == "2" && "$can_cake" -eq 1 ]] && SEL_Q="cake" || SEL_Q="fq"

# 7. 应用配置
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
