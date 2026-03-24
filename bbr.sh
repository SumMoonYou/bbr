#!/bin/bash

# =============================================================
# 脚本名称: BBR + BDP + QDisc 综合加速工具 (增强修复版)
# 修复内容: 解决 line 88 整数表达式错误，增强变量安全性
# =============================================================

if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行此脚本。"
   exit 1
fi

# 1. 确保安装 bc (计算核心)
install_bc() {
    if ! command -v bc >/dev/null 2>&1; then
        echo "正在安装必要组件 bc..."
        if command -v apt-get >/dev/null; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1
        elif command -v yum >/dev/null; then
            yum install -y bc >/dev/null 2>&1
        fi
    fi
}
install_bc

# 2. 状态检测函数 (增加空值处理)
check_status() {
    local cur_qdisc=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    local cur_bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local cur_rmem=$(sysctl net.core.rmem_max 2>/dev/null | awk '{print $3}')
    
    # 防止空值导致计算报错
    cur_rmem=${cur_rmem:-0}
    local cur_rmem_mb=$(echo "$cur_rmem / 1024 / 1024" | bc 2>/dev/null || echo "0")

    echo "-----------------------------------------------"
    echo "📊 当前系统网络加速状态:"
    echo "   >> 队列算法 (QDisc):  ${cur_qdisc:-未知}"
    echo "   >> 拥塞控制 (TCP):    ${cur_bbr:-未知}"
    echo "   >> 最大缓存 (Buffer): ${cur_rmem_mb} MB"
    echo "-----------------------------------------------"
}

clear
echo "==============================================="
echo "   TCP 综合加速工具 (BBR + BDP + QDisc)"
echo "==============================================="
check_status

echo "1) 应用/更新 加速配置"
echo "2) 卸载加速配置 (恢复系统默认)"
read -p "请选择 [1-2, 默认1]: " MAIN_CHOICE
MAIN_CHOICE=${MAIN_CHOICE:-1}

if [[ "$MAIN_CHOICE" == "2" ]]; then
    rm -f /etc/sysctl.d/99-net-speedup.conf
    sysctl --system > /dev/null
    echo "✅ 已卸载优化配置。"
    exit 0
fi

# 3. 内核版本安全识别 (修复 line 88 的根源)
kernel_ver=$(uname -r | cut -d- -f1 | awk -F. '{print $1"."$2}')
# 使用 bc 进行浮点数比较，避免 [ ] 整数比较报错
can_cake=$(echo "$kernel_ver >= 4.19" | bc 2>/dev/null)
can_cake=${can_cake:-0} # 如果 bc 报错，默认为 0 (不支持)

echo "-----------------------------------------------"
read -p "请输入下行带宽 (Mbps, 默认 1000): " BANDWIDTH
BANDWIDTH=${BANDWIDTH:-1000}
read -p "请输入目标延迟 (ms, 默认 160): " LATENCY
LATENCY=${LATENCY:-160}

# 4. BDP 计算 (增加安全限制)
BDP=$(echo "$BANDWIDTH * $LATENCY * 125 * 2" | bc 2>/dev/null)
BDP=${BDP:-16777216} # 失败则保底 16MB

if [ "$BDP" -lt 16777216 ]; then BDP=16777216; fi
if [ "$BDP" -gt 268435456 ]; then BDP=268435456; fi
MAX_BUF_MB=$(echo "$BDP / 1024 / 1024" | bc 2>/dev/null)

# 5. QDisc 菜单
echo "-----------------------------------------------"
echo "选择调度算法 (QDisc):"
echo "1) FQ   (BBR标配: 适合大流量下载)"
if [ "$can_cake" -eq 1 ]; then
    echo "2) CAKE (现代算法: 适合低延迟游戏)"
else
    echo "x) CAKE (内核 $kernel_ver 过低，暂不支持)"
fi
read -p "请选择 [1-2, 默认1]: " QCHOICE
QCHOICE=${QCHOICE:-1}

[[ "$QCHOICE" == "2" && "$can_cake" -eq 1 ]] && SELECTED_QDISC="cake" || SELECTED_QDISC="fq"

# 6. 写入配置
cat > /etc/sysctl.d/99-net-speedup.conf << EOF
net.core.default_qdisc = $SELECTED_QDISC
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = $BDP
net.core.wmem_max = $BDP
net.ipv4.tcp_rmem = 4096 87380 $BDP
net.ipv4.tcp_wmem = 4096 65536 $BDP
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
EOF

sysctl --system > /dev/null
echo "-----------------------------------------------"
echo "✅ 优化成功应用！"
check_status
