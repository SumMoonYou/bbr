#!/bin/bash

# =============================================================
# 脚本名称: BBR
# =============================================================

if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行此脚本。"
   exit 1
fi

# 1. 安装计算组件 bc
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y bc >/dev/null 2>&1
fi

clear
echo "==============================================="
echo "      TCP 综合调优工具 (FQ/CAKE 可选)"
echo "==============================================="

# 2. 参数输入
read -p "1. 服务器带宽 (Mbps, 默认 1000): " SRV_BW; SRV_BW=${SRV_BW:-1000}
read -p "2. 本地下载带宽 (Mbps, 默认 1000): " LOCAL_BW; LOCAL_BW=${LOCAL_BW:-1000}
read -p "3. 往返延迟 (ms, 默认 160): " LATENCY; LATENCY=${LATENCY:-160}

# 计算瓶颈带宽并计算 3 倍 BDP 缓存 (单线程优化核心)
if [ "$SRV_BW" -lt "$LOCAL_BW" ]; then FINAL_BW=$SRV_BW; else FINAL_BW=$LOCAL_BW; fi
BDP=$(echo "$FINAL_BW * $LATENCY * 125 * 3" | bc 2>/dev/null)
BDP=${BDP:-67108864}

# 内存限制：16MB ~ 512MB
[ "$BDP" -lt 16777216 ] && BDP=16777216
[ "$BDP" -gt 536870912 ] && BDP=536870912
MAX_BUF_MB=$(echo "$BDP / 1024 / 1024" | bc)

# 3. 算法选择交互
kernel_ver=$(uname -r | cut -d- -f1 | awk -F. '{print $1"."$2}')
can_cake=$(echo "$kernel_ver >= 4.19" | bc 2>/dev/null)
can_cake=${can_cake:-0}

echo "-----------------------------------------------"
echo "请选择排队算法 (QDisc):"
echo "1) FQ   (推荐: 追求单线程极限速度，适合测速/拉大文件)"
if [ "$can_cake" -eq 1 ]; then
    echo "2) CAKE (推荐: 追求网络平滑，适合游戏/视频通话，防抖动)"
else
    echo "x) CAKE (当前内核 $kernel_ver 过低，不支持)"
fi
read -p "请选择 [1-2, 默认1]: " QCHOICE; QCHOICE=${QCHOICE:-1}

if [[ "$QCHOICE" == "2" && "$can_cake" -eq 1 ]]; then
    SELECTED_QDISC="cake"
else
    SELECTED_QDISC="fq"
fi

# 4. 写入系统配置
cat > /etc/sysctl.d/99-net-speedup.conf << EOF
# 拥塞控制与算法选择
net.core.default_qdisc = $SELECTED_QDISC
net.ipv4.tcp_congestion_control = bbr

# TCP 缓冲区深度调优 (解决单线程跑不快)
net.core.rmem_max = $BDP
net.core.wmem_max = $BDP
net.ipv4.tcp_rmem = 4096 131072 $BDP
net.ipv4.tcp_wmem = 4096 131072 $BDP

# 链路增强参数
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_reordering = 10
net.ipv4.tcp_sack = 1
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
EOF

# 5. 生效
sysctl --system > /dev/null

echo "-----------------------------------------------"
echo "✅ 配置已成功应用！"
echo ">> 已安装算法: $SELECTED_QDISC + BBR"
echo ">> 理论缓冲区: ${MAX_BUF_MB} MB"
echo "-----------------------------------------------"
