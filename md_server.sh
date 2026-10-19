#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 服务器初始化脚本（Debian / Alpine 通用，幂等）
# 用法: sudo bash init.sh
# ============================================================

# 检测发行版（供后续使用）
if [ -f /etc/debian_version ]; then
    DISTRO="debian"
elif [ -f /etc/alpine-release ]; then
    DISTRO="alpine"
else
    DISTRO="unknown"
fi

# ============================================================
# 1. 设置主机名（检测已设置则跳过）
# ============================================================
CURRENT_HOSTNAME=$(hostname)
echo "当前主机名: $CURRENT_HOSTNAME"
read -rp "请输入新的主机名（直接回车保留当前）: " NEW_HOSTNAME

if [[ -z "$NEW_HOSTNAME" || "$NEW_HOSTNAME" == "$CURRENT_HOSTNAME" ]]; then
    echo "[SKIP] 主机名已为 $CURRENT_HOSTNAME，无需修改。"
else
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || {
        # Alpine 无 hostnamectl，使用 /etc/hostname
        echo "$NEW_HOSTNAME" > /etc/hostname
        hostname "$NEW_HOSTNAME"
    }
    if grep -q "^127.0.1.1" /etc/hosts; then
        sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
    else
        echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
    fi
    echo "[OK] 主机名已设置为: $NEW_HOSTNAME"
fi

# ============================================================
# 2. 添加公钥 + 开启密钥登录 + 关闭 root 密码 SSH
# ============================================================
read -rp "请输入要添加公钥的用户名 (默认 root): " SSH_USER
SSH_USER=${SSH_USER:-root}

if ! id "$SSH_USER" &>/dev/null; then
    echo "用户 $SSH_USER 不存在，退出。"
    exit 1
fi

USER_HOME=$(getent passwd "$SSH_USER" | cut -d: -f6)
AUTH_KEYS="$USER_HOME/.ssh/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

# ---- 2.1 公钥检测 ----
NEED_PUBKEY=1
if [ -f "$AUTH_KEYS" ] && [ -s "$AUTH_KEYS" ]; then
    echo "已存在的公钥条目："
    nl -ba "$AUTH_KEYS"
    read -rp "是否需要添加新公钥？(y/N): " ADD_KEY
    if [[ ! "$ADD_KEY" =~ ^[Yy]$ ]]; then
        NEED_PUBKEY=0
        echo "[SKIP] 公钥已存在，跳过添加。"
    fi
fi

if [ "$NEED_PUBKEY" -eq 1 ]; then
    echo "请粘贴公钥（一行，回车结束）:"
    read -r PUBKEY
    if [[ -z "$PUBKEY" ]]; then
        echo "公钥不能为空，退出。"
        exit 1
    fi
    mkdir -p "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    touch "$AUTH_KEYS"
    if grep -qF "$PUBKEY" "$AUTH_KEYS"; then
        echo "[SKIP] 该公钥已存在，跳过。"
    else
        echo "$PUBKEY" >> "$AUTH_KEYS"
        echo "[OK] 公钥已添加到 $AUTH_KEYS"
    fi
    chmod 600 "$AUTH_KEYS"
    chown -R "$SSH_USER:$SSH_USER" "$USER_HOME/.ssh"
fi

# ---- 2.2 sshd 配置检测 ----
set_sshd_option() {
    local key="$1" value="$2"
    if grep -qE "^\s*#?\s*${key}\b" "$SSHD_CONFIG"; then
        sed -i -E "s|^\s*#?\s*${key}\b.*|${key} ${value}|" "$SSHD_CONFIG"
    else
        echo "${key} ${value}" >> "$SSHD_CONFIG"
    fi
}

sshd_option_is() {
    local key="$1" value="$2"
    grep -qE "^\s*${key}\s+${value}\s*$" "$SSHD_CONFIG"
}

SSHD_CHANGED=0
if sshd_option_is "PubkeyAuthentication" "yes"; then
    echo "[SKIP] PubkeyAuthentication 已为 yes。"
else
    set_sshd_option "PubkeyAuthentication" "yes"
    SSHD_CHANGED=1
fi

if sshd_option_is "PasswordAuthentication" "yes"; then
    echo "[SKIP] PasswordAuthentication 已为 yes（普通用户仍可密码登录）。"
else
    set_sshd_option "PasswordAuthentication" "yes"
    SSHD_CHANGED=1
fi

if sshd_option_is "PermitRootLogin" "prohibit-password"; then
    echo "[SKIP] PermitRootLogin 已为 prohibit-password（root 禁止密码登录）。"
else
    set_sshd_option "PermitRootLogin" "prohibit-password"
    SSHD_CHANGED=1
fi

if sshd_option_is "ChallengeResponseAuthentication" "no"; then
    echo "[SKIP] ChallengeResponseAuthentication 已为 no。"
else
    set_sshd_option "ChallengeResponseAuthentication" "no"
    SSHD_CHANGED=1
fi

if [ "$SSHD_CHANGED" -eq 1 ]; then
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"
    if sshd -t 2>/dev/null || /usr/sbin/sshd -t; then
        if [ "$DISTRO" = "alpine" ]; then
            rc-service sshd restart
        else
            systemctl restart sshd 2>/dev/null || systemctl restart ssh
        fi
        echo "[OK] sshd 配置已更新并重启。"
    else
        echo "[ERROR] sshd 配置校验失败，已回滚。"
        cp "${SSHD_CONFIG}.bak."* "$SSHD_CONFIG"
        exit 1
    fi
else
    echo "[SKIP] sshd 配置均已符合要求，无需重启。"
fi

# ============================================================
# 3. 登录时自动打印系统信息（检测已配置则跳过）
# ============================================================
PROFILE_FILE="$USER_HOME/.profile"
FETCH_MARKER="# --- auto fetch ---"

if grep -qF "$FETCH_MARKER" "$PROFILE_FILE" 2>/dev/null; then
    echo "[SKIP] $PROFILE_FILE 中已存在自动显示配置，跳过。"
else
    FETCH_CMD=""
    if command -v fastfetch &>/dev/null; then
        FETCH_CMD="fastfetch"
    elif command -v neofetch &>/dev/null; then
        FETCH_CMD="neofetch"
    else
        echo "尝试安装 fastfetch 或 neofetch..."
        case "$DISTRO" in
            debian)
                apt-get update &>/dev/null
                apt-get install -y fastfetch &>/dev/null && FETCH_CMD="fastfetch" \
                    || { apt-get install -y neofetch &>/dev/null && FETCH_CMD="neofetch"; }
                ;;
            alpine)
                apk update &>/dev/null
                apk add fastfetch &>/dev/null && FETCH_CMD="fastfetch" \
                    || { apk add neofetch &>/dev/null && FETCH_CMD="neofetch"; }
                ;;
            *)
                echo "[WARN] 未识别的发行版，跳过安装。"
                ;;
        esac
    fi

    if [ -n "$FETCH_CMD" ]; then
        touch "$PROFILE_FILE"
        chown "$SSH_USER:$SSH_USER" "$PROFILE_FILE" 2>/dev/null || true
        cat >> "$PROFILE_FILE" <<EOF

$FETCH_MARKER
if command -v $FETCH_CMD &>/dev/null; then
    $FETCH_CMD
fi
EOF
        echo "[OK] 已将 $FETCH_CMD 添加到 $PROFILE_FILE（登录时自动显示）。"
    else
        echo "[WARN] 未找到可用的 fastfetch/neofetch，跳过。"
    fi
fi

echo "初始化完成。请保持当前会话不要断开，另开终端验证密钥登录后再退出。"
