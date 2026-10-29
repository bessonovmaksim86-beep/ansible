#!/usr/bin/env bash
#
# provision-wsl-rootfs.sh — первичная настройка Debian slim-образа,
# импортированного в WSL2 (wsl --import). От root.
#
#   wsl -d Debian -u root -- bash /mnt/d/.../scripts/provision-wsl-rootfs.sh
#
# Slim-образ Debian не содержит systemd, sudo, пользователя и базовых утилит,
# поэтому до запуска setup-wsl-debian.sh нужно доставить их.
#
set -euo pipefail

ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin123}"

echo "=== 1. /etc/wsl.conf: systemd + отключить PATH из Windows ==="
cat > /etc/wsl.conf <<'EOF'
[boot]
systemd=true

[interop]
enabled=false
appendWindowsPath=false

[user]
default=admin
EOF
cat /etc/wsl.conf

echo
echo "=== 2. Пакеты: systemd, sudo, базовое ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  systemd systemd-sysv sudo procps iproute2 kmod \
  locales ca-certificates curl gnupg acl git openssl \
  python3 python3-pymysql rsync cron

echo
echo "=== 3. Пользователь ${ADMIN_USER} с sudo NOPASSWD ==="
if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
  useradd -m -G sudo -s /bin/bash "${ADMIN_USER}"
  echo "${ADMIN_USER}:${ADMIN_PASS}" | chpasswd
  echo "создан пользователь ${ADMIN_USER} (пароль: ${ADMIN_PASS})"
else
  usermod -aG sudo "${ADMIN_USER}"
fi
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${ADMIN_USER}" > "/etc/sudoers.d/90-${ADMIN_USER}"
chmod 440 "/etc/sudoers.d/90-${ADMIN_USER}"

echo
echo "=== 4. Локаль ==="
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true

echo
echo "=== 5. Проверка ==="
echo "systemd:        $(dpkg-query -W -f='${Version}' systemd 2>/dev/null || echo 'нет')"
echo "systemd-sysv:   $(dpkg-query -W -f='${Version}' systemd-sysv 2>/dev/null || echo 'нет')"
echo "sudo:           $(dpkg-query -W -f='${Version}' sudo 2>/dev/null || echo 'нет')"
echo "python3:        $(python3 --version 2>&1)"
echo "пользователь:   $(id "${ADMIN_USER}")"

cat <<'EOF'

========================================================================
  ГОТОВО. systemd активируется только после перезапуска WSL:

     wsl --shutdown          (в PowerShell)

  После этого проверить:
     wsl -d Debian -u admin -- bash -c "ps -p 1 -o comm="     -> systemd
========================================================================
EOF
