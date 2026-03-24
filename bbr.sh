#!/bin/bash

# =============================================================
# 脚本名称: BBR + BDP + QDisc 综合加速工具 (专业注释版)
# 默认参数: 带宽 1000 Mbps / 延迟 160 ms
# 适用环境: 跨境长距离传输、高带宽服务器、游戏/视频加速
# =============================================================

# 检查是否以 root 权限运行，修改内核参数必须需要 root
if [[ $EUID -ne 0 ]]; then
   echo "错误: 请使用 root 权限运行此脚本。"
   exit 1
fi

# 自动安装 bc 计算器（Bash 原生不支持浮点运算，计算 BDP 必须用到它）
if command -v apt-get >/dev/null; then
    apt-get update -y >/dev/null 2>&1 && apt-get install -y bc >/dev/null 2>&1
elif command -v yum >/dev/null; then
    yum install -y bc >/dev/null 2>&1
fi

# --- 函数：实时检测并显示当前内核网络参数 ---
check_status() {
    # 获取当前系统默认的队列调度算法
    local cur_qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}')
    # 获取当前生效的 TCP 拥塞控制算法
    local cur_bbr=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    # 获取当前最大接收缓冲区大小 (Bytes)
    local cur_rmem=$(sysctl net.core.rmem_max | awk '{print $3}')
    # 将字节转换为 MB 方便阅读
    local cur_rmem_mb=$(echo "$cur_rmem / 1024 / 1024" | bc)

    echo "-----------------------------------------------"
    echo "📊 当前系统网络加速状态:"
    echo "   >> 队列算法 (QDisc):  $cur_qdisc"
    echo "   >> 拥塞控制 (TCP):    $cur_bbr"
    echo "   >> 最大缓存 (Buffer): ${cur_rmem_mb} MB"
    echo "-----------------------------------------------"
}

clear
echo "==============================================="
echo "   TCP 综合加速工具 (BBR + BDP + QDisc)"
echo "==============================================="
check_status # 展示当前配置

echo "1) 应用/更新 加速配置"
echo "2) 卸载加速配置 (恢复系统默认)"
read -p "请选择 [1-2, 默认1]: " MAIN_CHOICE
MAIN_CHOICE=${MAIN_CHOICE:-1}

# 卸载逻辑：删除自定义配置文件并重新加载系统默认值
if [[ "$MAIN_CHOICE" == "2" ]]; then
    rm -f /etc/sysctl.d/99-net-speedup.conf
    sysctl --system > /dev/null
    echo "✅ 已卸载优化配置，系统已恢复默认。"
    exit 0
fi

# 环境识别：BBR 需要 4.9+，CAKE 算法建议 4.19+
kernel_ver=$(uname -r | cut -d- -f1)
can_cake=$(echo "$kernel_ver >= 4.19" | bc)

# 参数交互：获取用户带宽和延迟数据
echo "-----------------------------------------------"
echo "💡 提示: 直接回车将使用预设值 (1000M / 160ms)"
read -p "请输入下行带宽 (Mbps, 默认 1000): " BANDWIDTH
BANDWIDTH=${BANDWIDTH:-1000}

read -p "请输入目标延迟 (ms, 默认 160): " LATENCY
LATENCY=${LATENCY:-160}

# --- 核心计算：BDP (带宽时延乘积) ---
# 计算公式：(带宽 Mbps * 10^6 / 8 转换成字节) * (延迟 ms / 10^3 转换成秒)
# 简化系数：带宽 * 延迟 * 125
# 预留 2 倍：应对网络剧烈抖动时的突发流量缓存
BDP=$(echo "$BANDWIDTH * $LATENCY * 125 * 2" | bc)

# 边界值保护：最小不低于 16MB，最大不超过 256MB（防止小内存 VPS 爆内存）
[ "$BDP" -lt 16777216 ] && BDP=16777216
[ "$BDP" -gt 268435456 ] && BDP=268435456
MAX_BUF_MB=$(echo "$BDP / 1024 / 1024" | bc)

# 算法菜单选择
echo "-----------------------------------------------"
echo "选择调度算法 (QDisc):"
echo "1) FQ   (BBR标配: 适合极致吞吐、看 4K 视频、拉大文件)"
if [ "$can_cake" -eq 1 ]; then
    echo "2) CAKE (现代算法: 智能分配带宽、显著改善游戏/语音延迟)"
else
    echo "x) CAKE (当前内核 $kernel_ver 过低，暂不支持)"
fi
read -p "请选择 [1-2, 默认1]: " QCHOICE
QCHOICE=${QCHOICE:-1}

if [[ "$QCHOICE" == "2" && "$can_cake" -eq 1 ]]; then
    SELECTED_QDISC="cake"
else
    SELECTED_QDISC="fq"
fi

# --- 写入持久化内核配置 ---
# 使用 sysctl.d 目录，不破坏主配置，优先级更高
cat > /etc/sysctl.d/99-net-speedup.conf << EOF
# 开启 BBR 拥塞控制算法
net.core.default_qdisc = $SELECTED_QDISC
net.ipv4.tcp_congestion_control = bbr

# TCP 接收/发送缓冲区最大值限制 (由 BDP 计算得出)
net.core.rmem_max = $BDP
net.core.wmem_max = $BDP

# TCP 缓冲区自动调整参数: [最小 初始 最大]
net.ipv4.tcp_rmem = 4096 87380 $BDP
net.ipv4.tcp_wmem = 4096 65536 $BDP

# 启用窗口缩放因子 (必须开启，否则最大窗口受限于 64KB)
net.ipv4.tcp_window_scaling = 1

# 开启 MTU 探测（自动发现路径最优包大小，解决部分线路“大包被丢弃”导致的断连）
net.ipv4.tcp_mtu_probing = 1

# 禁用闲置后的慢启动（防止连接建立一段时间不传输后速度降到最低）
net.ipv4.tcp_slow_start_after_idle = 0

# 设置“未发送数据”低水位，有效缓解 BBR 的缓冲区膨胀（Bufferbloat）
net.ipv4.tcp_notsent_lowat = 16384

# 快速回收/重用 TIME_WAIT 连接，适合高并发短连接场景
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_tw_reuse = 1
EOF

# 应用配置：立即载入所有 sysctl 参数
sysctl --system > /dev/null

echo "-----------------------------------------------"
echo "✅ 优化成功应用！"
check_status # 再次显示，确认参数已写入内核
echo "-----------------------------------------------"
echo "建议：如果是为了下载速度选 FQ；如果是为了降低游戏抖动选 CAKE。"
