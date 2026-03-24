#!/bin/bash

# =============================================================
# 脚本名称: BBR + BDP 综合加速工具 (全参数定制版)
# 适用场景: 跨国链路、高带宽/高延迟环境 (如 1000M 宽带, 160ms 延迟)
# =============================================================

# 检查 Root 权限
if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行此脚本。"
   exit 1
fi

# 1. 自动安装计算组件 bc (用于处理脚本中的数学运算)
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

# 2. 状态监测函数：显示当前内核参数
check_status() {
    local cur_qdisc=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    local cur_bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local cur_rmem=$(sysctl net.core.rmem_max 2>/dev/null | awk '{print $3}')
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
echo "      TCP BDP 动态调优工具 (全参数版)"
echo "==============================================="
check_status

# 3. 菜单选择
echo "1) 应用/更新 优化配置"
echo "2) 卸载配置 (恢复系统默认)"
read -p "请选择 [1-2, 默认1]: " MAIN_CHOICE
MAIN_CHOICE=${MAIN_CHOICE:-1}

if [[ "$MAIN_CHOICE" == "2" ]]; then
    rm -f /etc/sysctl.d/99-net-speedup.conf
    sysctl --system > /dev/null
    echo "✅ 已清除优化配置，系统已恢复默认。"
    exit 0
fi

# 4. 手动参数输入
echo "-----------------------------------------------"
echo "💡 请输入以下参数（直接回车使用默认值）"
echo "-----------------------------------------------"

# 服务器带宽
read -p "1. 服务器出口带宽 (Mbps, 默认 1000): " SRV_BW
SRV_BW=${SRV_BW:-1000}

# 本地带宽
read -p "2. 本地下载带宽 (Mbps, 默认 1000): " LOCAL_BW
LOCAL_BW=${LOCAL_BW:-1000}

# 延迟
read -p "3. 目标延迟/Ping (ms, 默认 160): " LATENCY
LATENCY=${LATENCY:-160}

# 5. 计算有效带宽 (取两端最小值)
if [ "$SRV_BW" -lt "$LOCAL_BW" ]; then
    FINAL_BW=$SRV_BW
else
    FINAL_BW=$LOCAL_BW
fi

# 6. 计算 BDP (带宽时延乘积)
# 公式: 带宽(Mbps) * 延迟(ms) * 125 * 2倍系数
BDP=$(echo "$FINAL_BW * $LATENCY * 125 * 2" | bc 2>/dev/null)
BDP=${BDP:-16777216} # 失败则保底 16MB

# 限制范围：16MB ~ 512MB (防止超大带宽导致内存溢出)
[ "$BDP" -lt 16777216 ] && BDP=16777216
[ "$BDP" -gt 536870912 ] && BDP=536870912
MAX_BUF_MB=$(echo "$BDP / 1024 / 1024" | bc 2>/dev/null)

# 7. QDisc 选择 (内核 4.19+ 支持 CAKE)
kernel_ver=$(uname -r | cut -d- -f1 | awk -F. '{print $1"."$2}')
can_cake=$(echo "$kernel_ver >= 4.19" | bc 2>/dev/null)
can_cake=${can_cake:-0}

echo "-----------------------------------------------"
echo "请选择队列算法 (QDisc):"
echo "1) FQ   (推荐: 配合BBR最稳, 适合测速/拉大文件)"
if [ "$can_cake" -eq 1 ]; then
    echo "2) CAKE (现代: 延迟更平稳, 适合游戏/视频通话)"
fi
read -p "选择 [1-2, 默认1]: " QCHOICE
QCHOICE=${QCHOICE:-1}

[[ "$QCHOICE" == "2" && "$can_cake" -eq 1 ]] && SELECTED_QDISC="cake" || SELECTED_QDISC="fq"

# 8. 写入系统配置文件 (带详细注释)
cat > /etc/sysctl.d/99-net-speedup.conf << EOF
# --- 拥塞控制 ---
net.core.default_qdisc = $SELECTED_QDISC
net.ipv4.tcp_congestion_control = bbr

# --- TCP 缓冲区调优 (基于 ${FINAL_BW}Mbps/${LATENCY}ms 计算) ---
# 系统最大接收/发送缓冲区 (单位: 字节)
net.core.rmem_max = $BDP
net.core.wmem_max = $BDP
# TCP 读缓存: [最小 初始 最大]
net.ipv4.tcp_rmem = 4096 87380 $BDP
# TCP 写缓存: [最小 初始 最大]
net.ipv4.tcp_wmem = 4096 65536 $BDP

# --- 链路稳定性优化 ---
# 开启窗口缩放，支持超大 BDP 传输
net.ipv4.tcp_window_scaling = 1
# 开启 MTU 探测，防止由于路径 MTU 不一致导致的断连
net.ipv4.tcp_mtu_probing = 1
# 禁用闲置后的慢启动，保持传输速度稳定
net.ipv4.tcp_slow_start_after_idle = 0
# 减少连接关闭时的等待时间，加快资源回收
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
# 配合 BBR 减少缓冲区膨胀延迟
net.ipv4.tcp_notsent_lowat = 16384
EOF

# 9. 应用并完成
sysctl --system > /dev/null
echo "-----------------------------------------------"
echo "✅ 优化已应用！"
echo "计算基准带宽: ${FINAL_BW} Mbps"
echo "计算基准延迟: ${LATENCY} ms"
check_status
echo "==============================================="
