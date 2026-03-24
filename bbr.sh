#!/bin/bash

# =============================================================
# 脚本名称: BBR + BDP 综合调优 (单/多线程全能版)
# =============================================================

if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行此脚本。"
   exit 1
fi

# 1. 自动安装计算组件 bc
if command -v apt-get >/dev/null; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1
elif command -v yum >/dev/null; then
    yum install -y bc >/dev/null 2>&1
fi

# --- 2. 状态监测函数 ---
check_status() {
    local cur_qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}')
    local cur_bbr=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    local cur_rmem=$(sysctl net.core.rmem_max | awk '{print $3}')
    cur_rmem=${cur_rmem:-0}
    local cur_rmem_mb=$(echo "$cur_rmem / 1024 / 1024" | bc)

    echo "-----------------------------------------------"
    echo "📊 当前网络参数状态:"
    echo "   >> 队列算法: $cur_qdisc | 拥塞控制: $cur_bbr"
    echo "   >> TCP 最大单向缓存: ${cur_rmem_mb} MB"
    echo "-----------------------------------------------"
}

clear
echo "==============================================="
echo "     TCP 全场景加速工具 (单/多线程优化)"
echo "==============================================="
check_status

# 3. 参数手动输入
echo "💡 直接回车使用预设值 (1000M / 160ms)"
read -p "1. 服务器带宽 (Mbps, 默认 1000): " SRV_BW; SRV_BW=${SRV_BW:-1000}
read -p "2. 本地下载带宽 (Mbps, 默认 1000): " LOCAL_BW; LOCAL_BW=${LOCAL_BW:-1000}
read -p "3. 往返延迟 (ms, 默认 160): " LATENCY; LATENCY=${LATENCY:-160}

# 计算逻辑：取两端带宽最小值
FINAL_BW=$(([ $SRV_BW < $LOCAL_BW ] && echo $SRV_BW) || echo $LOCAL_BW)

# 计算 BDP：为了单线程极限速度，采用 3 倍 BDP 冗余
# 带宽 * 延迟 * 125 * 3
BDP=$(echo "$FINAL_BW * $LATENCY * 125 * 3" | bc)

# 内存安全保护：保底 32MB，最高 512MB (防止大带宽耗尽服务器内存)
[ "$BDP" -lt 33554432 ] && BDP=33554432
[ "$BDP" -gt 536870912 ] && BDP=536870912
MAX_BUF_MB=$(echo "$BDP / 1024 / 1024" | bc)

# 4. QDisc 算法选择 (FQ/CAKE)
kernel_ver=$(uname -r | cut -d- -f1 | awk -F. '{print $1"."$2}')
can_cake=$(echo "$kernel_ver >= 4.19" | bc)
echo "-----------------------------------------------"
echo "选择调度算法 (QDisc):"
echo "1) FQ   (单线程跑分更高，大文件传输最快)"
[[ "$can_cake" -eq 1 ]] && echo "2) CAKE (抗丢包、防抖动，游戏/语音体验更佳)"
read -p "请选择 [1-2, 默认1]: " QCHOICE; QCHOICE=${QCHOICE:-1}
[[ "$QCHOICE" == "2" && "$can_cake" -eq 1 ]] && SELECTED_QDISC="cake" || SELECTED_QDISC="fq"

# --- 5. 写入核心内核参数 (详细注释) ---
cat > /etc/sysctl.d/99-extreme-speedup.conf << EOF
# 开启 BBR 拥塞控制
net.core.default_qdisc = $SELECTED_QDISC
net.ipv4.tcp_congestion_control = bbr

# --- 核心缓冲区调优 ---
# 允许系统分配的最大缓存 (BDP * 系数)
net.core.rmem_max = $BDP
net.core.wmem_max = $BDP
# TCP 接收/发送缓冲区 [最小 初始上限 运行上限]
# 初始上限调大到 128KB，能显著提升单线程起步速度
net.ipv4.tcp_rmem = 4096 131072 $BDP
net.ipv4.tcp_wmem = 4096 131072 $BDP

# --- 进阶优化：解决单线程与跨国丢包 ---
# 提高包重排阈值 (3->6)，防止跨境链路微量乱序导致单线程误判丢包降速
net.ipv4.tcp_reordering = 6
# 开启 MTU 探测，自动适应最佳包大小
net.ipv4.tcp_mtu_probing = 1
# 禁用闲置后的慢启动，保持传输窗口始终处于“热启动”状态
net.ipv4.tcp_slow_start_after_idle = 0
# 开启选择性确认 (SACK)，丢包时只重传丢失的部分
net.ipv4.tcp_sack = 1
# 降低 ACK 延迟确认，让单线程更快获取下一批数据的发送权
net.ipv4.tcp_low_latency = 1
# 优化连接回收
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
# 针对 BBR 降低缓冲区膨胀，提升响应速度
net.ipv4.tcp_notsent_lowat = 16384
EOF

# 6. 生效配置
sysctl --system > /dev/null
echo "-----------------------------------------------"
echo "✅ 全能加速配置已成功应用！"
check_status
echo "温馨提示：如需测试单线程极限，请直接用浏览器下载文件测试。"
echo "==============================================="
