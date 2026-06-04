#!/usr/bin/env bash
# create_user_with_key.sh
# 用法：
#   sudo ./create_user_with_key.sh <username> <password> <pubkey-or-filepath> [--shell /bin/bash]
#
# 示例：
#   sudo ./create_user_with_key.sh alice 'MyPassw0rd!' "ssh-ed25519 AAAAC3..." --shell /bin/bash
#   sudo ./create_user_with_key.sh devops '123456' ~/.ssh/id_ed25519.pub

set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "请用 root 权限运行（例如：sudo $0 ...）" >&2
  exit 1
fi

if [[ $# -lt 3 ]]; then
  echo "用法：$0 <username> <password> <pubkey-or-filepath> [--shell /path/to/shell]" >&2
  exit 2
fi

USERNAME="$1"
PASSWORD="$2"
PUBKEY_INPUT="$3"
shift 3

USER_SHELL="/bin/bash"   # 默认给 bash，比 nologin 实用

# 可选参数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      if [[ $# -lt 2 ]]; then
        echo "--shell 需要一个参数" >&2; exit 2
      fi
      USER_SHELL="$2"; shift 2
      ;;
    *)
      echo "未知参数：$1" >&2; exit 2
      ;;
  esac
done

# 读取公钥
if [[ -f "$PUBKEY_INPUT" ]]; then
  PUBKEY="$(cat "$PUBKEY_INPUT")"
else
  PUBKEY="$PUBKEY_INPUT"
fi

if [[ -z "${PUBKEY// }" ]]; then
  echo "公钥内容为空。" >&2
  exit 3
fi

# 创建用户
if id -u "$USERNAME" >/dev/null 2>&1; then
  echo "用户 $USERNAME 已存在，跳过创建。"
else
  adduser --disabled-password --gecos "" --shell "$USER_SHELL" "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd
  echo "已创建用户 $USERNAME 并设置密码。"
fi

# 默认加入 sudo 组
usermod -aG sudo "$USERNAME"
echo "已将 $USERNAME 加入 sudo 组。"

# 配置 SSH 公钥
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
SSH_DIR="$USER_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
if [[ -f "$AUTH_KEYS" ]] && grep -qF "$PUBKEY" "$AUTH_KEYS"; then
  echo "authorized_keys 中已存在该公钥，跳过追加。"
else
  echo "$PUBKEY" >> "$AUTH_KEYS"
  echo "已写入公钥到 $AUTH_KEYS。"
fi

# 权限
chown -R "$USERNAME":"$USERNAME" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"

echo "✅ 完成：用户 $USERNAME 已创建，密码和 SSH 公钥已设置，并已加入 sudo 组。"

