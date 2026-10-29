#!/usr/bin/env bash
#
# bootstrap-host.sh — разовая подготовка чистого Debian-хоста перед первым
# прогоном Ansible: ключ SSH, пользователь с sudo NOPASSWD, python3.
#
#   export TARGET_HOST=1.2.3.4 TARGET_USER=root
#   ./scripts/bootstrap-host.sh
#
# После этого в инвентаре используется ansible_user: admin и ключ id_ed25519.
set -euo pipefail

TARGET_HOST="${TARGET_HOST:?Укажите TARGET_HOST, например export TARGET_HOST=1.2.3.4}"
TARGET_USER="${TARGET_USER:-root}"
ADMIN_USER="${ADMIN_USER:-admin}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

[[ -f "${SSH_KEY}" ]] || { echo ">>> Генерирую SSH-ключ ${SSH_KEY}"; ssh-keygen -t ed25519 -N "" -f "${SSH_KEY}"; }

echo ">>> Копирую публичный ключ на ${TARGET_USER}@${TARGET_HOST}"
ssh-copy-id -o StrictHostKeyChecking=accept-new "${TARGET_USER}@${TARGET_HOST}"

echo ">>> Создаю пользователя ${ADMIN_USER}, включаю sudo NOPASSWD, ставлю python3"
ssh -o StrictHostKeyChecking=accept-new "${TARGET_USER}@${TARGET_HOST}" bash -s <<EOF
set -e
id -u ${ADMIN_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${ADMIN_USER}
install -d -m 700 -o ${ADMIN_USER} -g ${ADMIN_USER} /home/${ADMIN_USER}/.ssh
grep -qF "$(cat ${SSH_KEY}.pub)" /home/${ADMIN_USER}/.ssh/authorized_keys 2>/dev/null \
  || cat ${SSH_KEY}.pub >> /home/${ADMIN_USER}/.ssh/authorized_keys
chmod 600 /home/${ADMIN_USER}/.ssh/authorized_keys
chown ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.ssh/authorized_keys
echo '${ADMIN_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-${ADMIN_USER}
chmod 440 /etc/sudoers.d/90-${ADMIN_USER}
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sudo python3 openssh-server
systemctl enable --now ssh
EOF

echo ""
echo "Готово. Проверка подключения:"
echo "  ansible -i inventories/dev all -m ping"
