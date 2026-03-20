#!/bin/bash
# =================================================
# 代理服务器性能优化脚本（BBR + fq-pie）
# 专注多线程性能优化
# 兼容：Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux
# =================================================

set -e

SYSCTL_CONF="/etc/sysctl.d/99-bbr-fqpie.conf"
LIMITS_CONF="/etc/security/limits.d/99-nofile-nproc.conf"
SYSTEMD_CONF="/etc/systemd/system.conf.d/99-limits.conf"

# 必须 root
if [ "$(id -u)" -ne 0 ]; then
    clear
    echo "Error: This script must be run as root!"
    exit 1
fi

# 获取当前加速方式
function get_bbr_status() {
    TCP_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
    QDISC=$(sysctl -n net.core.default_qdisc)
    if [ "$TCP_CC" == "bbr" ] && [ "$QDISC" == "fq_pie" ]; then
        echo "BBR + fq-pie (TCP 加速)"
    elif [ "$TCP_CC" == "bbr" ]; then
        echo "BBR + $QDISC (TCP 加速，但队列非 fq-pie)"
    else
        echo "$TCP_CC + $QDISC (未启用 BBR)"
    fi
}

# 安装 / 开启 BBR + fq-pie
function install_bbr() {
    echo "正在配置 BBR + fq-pie..."

    # 强制设置 BBR 和 fq-pie 队列
    sudo sysctl -w net.ipv4.tcp_congestion_control=bbr  # 切换到 BBR 拥塞控制
    sudo sysctl -w net.core.default_qdisc=fq_pie  # 切换到 fq-pie 队列调度器
    sudo sysctl --system  # 重新加载配置

    # 写入 BBR + fq-pie 配置
    cat > $SYSCTL_CONF <<EOF
# 启用 BBR 和 fq-pie
net.core.default_qdisc=fq_pie
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_tw_reuse=1
net.core.netdev_max_backlog=250000
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=4096
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 87380 16777216
net.ipv4.tcp_fastopen=3
fs.file-max=1000000
EOF

    # 优化 TCP 参数
    cat > /etc/sysctl.d/99-tcp-tuning.conf <<EOF
fs.file-max = 524288
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq_pie
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_rmem = 8192 262144 536870912
net.ipv4.tcp_wmem = 4096 16384 536870912
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_notsent_lowat = 131072
EOF

    # 加载 sysctl 配置
    sysctl --system

    # 配置系统资源限制
    cat > $LIMITS_CONF <<EOF
* soft     nproc    131072
* hard     nproc    131072
* soft     nofile   262144
* hard     nofile   262144

root soft  nproc    131072
root hard  nproc    131072
root soft  nofile   262144
root hard  nofile   262144
EOF

    # 配置 systemd 默认限制
    mkdir -p /etc/systemd/system.conf.d
    cat > $SYSTEMD_CONF <<EOF
[Manager]
DefaultLimitNOFILE=262144
DefaultLimitNPROC=131072
EOF

    # 重新加载 systemd 配置
    systemctl daemon-reexec

    echo "BBR + fq-pie 已启用 ✅ 当前加速方式: $(get_bbr_status)"
}

# 卸载 / 恢复默认
function uninstall_bbr() {
    if [ -f "$SYSCTL_CONF" ]; then
        rm -f "$SYSCTL_CONF"
        sysctl --system
        echo "BBR 已卸载，当前加速方式: $(get_bbr_status)"
    else
        echo "BBR 未安装或已卸载"
    fi
}

# 查看状态
function status_bbr() {
    echo "当前加速方式: $(get_bbr_status)"
}

# 连接复用与 TCP 优化
function optimize_connections() {
    echo "正在优化连接复用和 TCP 参数..."

    # 启用 TCP Keepalive 和 Fast Open
    sysctl -w net.ipv4.tcp_keepalive_time=120
    sysctl -w net.ipv4.tcp_keepalive_intvl=30
    sysctl -w net.ipv4.tcp_keepalive_probes=5
    sysctl -w net.ipv4.tcp_fastopen=3

    # 增加最大文件描述符
    ulimit -n 1000000

    echo "连接复用与 TCP 优化完成！"
}

# SSH 终端菜单
function menu() {
    while true; do
        clear
        echo "========================================"
        echo "        SSH 网络优化管理脚本"
        echo "========================================"
        echo "当前加速方式: $(get_bbr_status)"
        echo "----------------------------------------"
        echo "1) 安装 / 开启 BBR + fq-pie"
        echo "2) 卸载 / 恢复默认"
        echo "3) 查看加速状态"
        echo "4) 优化连接与 TCP 参数"
        echo "0) 退出"
        echo "----------------------------------------"
        read -p "请选择操作: " choice
        case $choice in
            1) install_bbr; read -p "按回车继续..." ;;
            2) uninstall_bbr; read -p "按回车继续..." ;;
            3) status_bbr; read -p "按回车继续..." ;;
            4) optimize_connections; read -p "按回车继续..." ;;
            0) exit 0 ;;
            *) echo "无效选项"; read -p "按回车继续..." ;;
        esac
    done
}

menu
