#!/usr/bin/env bash
#
# setup-wsl-debian.sh — подготовка Debian внутри WSL2 к прогону Ansible.
# Запускать ВНУТРИ Debian (не в Git Bash), полный путь к проекту на диске D:
#   sudo bash "/mnt/d/Новая папка/Ansible/ansible-lamp-wordpress/scripts/setup-wsl-debian.sh"
#
# Что делает:
#   1. ставит python3, sudo, базовые утилиты;
#   2. выдаёт текущему пользователю sudo NOPASSWD (нужно для become);
#   3. ставит Ansible и коллекции из requirements.yml;
#   4. копирует проект из /mnt/d/... в домашний каталог (работа с /mnt/d
#      медленная и ломает права/симлинки).
#
# Про systemd. В «встроенном» WSL поколения 2021 года (ядро 5.10, Windows 10
# 21H2) systemd не поднимается как PID 1 даже с [boot] systemd=true — PID 1
# остаётся /init. Поэтому сервисы управляются через sysvinit, а в ролях
# менеджер задаётся переменной service_use (см. docs/WSL2.md, шаг 1.5).
# Флаг WITH_SYSTEMD=1 доустанавливает пакеты systemd и включает его в
# /etc/wsl.conf - это имеет смысл только на актуальных сборках WSL (Windows 11).
#
set -euo pipefail

# Пользователь, от которого запускали sudo (а не root)
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_HOME="$(getent passwd "${RUN_USER}" | cut -d: -f6)"
PROJECT_SRC="${PROJECT_SRC:-}"

echo "=== 1. Проверка окружения ==="
if [[ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
  echo "Похоже, это не WSL. Скрипт предназначен для Debian внутри WSL2." >&2
  exit 1
fi
. /etc/os-release
echo "Дистрибутив: ${PRETTY_NAME}, пользователь: ${RUN_USER}"

echo
echo "=== 2. Пакеты: python3, sudo, базовое ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  python3 python3-pip python3-venv python3-cryptography python3-pymysql \
  sudo curl wget ca-certificates gnupg acl git openssl locales cron rsync

if [[ "${WITH_SYSTEMD:-0}" == "1" ]]; then
  echo
  echo "=== 2.1. systemd: пакеты + включение в /etc/wsl.conf (только WSL 2.x+) ==="
  apt-get install -y -qq --no-install-recommends systemd systemd-sysv
  mkdir -p /etc/wsl.conf.bak
  if [[ -f /etc/wsl.conf ]]; then cp -f /etc/wsl.conf "/etc/wsl.conf.bak/wsl.conf.$(date +%s)"; fi
  if grep -qE '^systemd\s*=\s*true' /etc/wsl.conf 2>/dev/null; then
    echo "systemd уже включён."
    SYSTEMD_JUST_ENABLED=0
  else
    printf '[boot]\nsystemd=true\n\n[interop]\nenabled=true\nappendWindowsPath=false\n' >> /etc/wsl.conf
    echo "systemd включён в /etc/wsl.conf. ПОНАДОБИТСЯ ПЕРЕЗАПУСК WSL: wsl --shutdown"
    SYSTEMD_JUST_ENABLED=1
  fi
else
  SYSTEMD_JUST_ENABLED=0
fi

echo
echo "=== 3. sudo NOPASSWD для ${RUN_USER} ==="
usermod -aG sudo "${RUN_USER}"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${RUN_USER}" > "/etc/sudoers.d/90-${RUN_USER}"
chmod 440 "/etc/sudoers.d/90-${RUN_USER}"

if [[ "${SYSTEMD_JUST_ENABLED}" == "1" ]]; then
  cat <<EOF

========================================================================
  ДАЛЬНЕЙШИЕ ШАГИ (systemd заработает только после перезапуска WSL):

  1. Выйдите из Debian:            exit
  2. В PowerShell (обычном):       wsl --shutdown
  3. Снова откройте Debian из Пуска.
  4. Проверьте:                    ps -p 1 -o comm=      -> должно быть "systemd"
  5. Запустите этот скрипт ПОВТОРНО: sudo bash setup-wsl-debian.sh
========================================================================
EOF
  exit 0
fi

echo
echo "=== 4. Ansible (свежая версия в отдельном venv) ==="
# Пакет ansible из Debian 12 = ansible-core 2.14, а community.general 8.x требует
# >= 2.15, поэтому ставим ansible-core pip'ом в изолированный venv.
if [[ -x /opt/ansible-venv/bin/ansible-playbook ]]; then
  echo "Ansible уже установлен: $(/opt/ansible-venv/bin/ansible --version | head -1)"
else
  python3 -m venv /opt/ansible-venv
  /opt/ansible-venv/bin/pip install --quiet --upgrade pip
  /opt/ansible-venv/bin/pip install --quiet "ansible-core>=2.16"
  ln -sf /opt/ansible-venv/bin/ansible-playbook /usr/local/bin/ansible-playbook
  ln -sf /opt/ansible-venv/bin/ansible /usr/local/bin/ansible
  ln -sf /opt/ansible-venv/bin/ansible-galaxy /usr/local/bin/ansible-galaxy
  ln -sf /opt/ansible-venv/bin/ansible-vault /usr/local/bin/ansible-vault
fi

echo
echo "=== 5. Размещение проекта ==="
# Ищем проект: явный PROJECT_SRC, иначе /mnt/d/Новая папка/Ansible/ansible-lamp-wordpress
if [[ -z "${PROJECT_SRC}" ]]; then
  for cand in "/mnt/d/Новая папка/Ansible/ansible-lamp-wordpress" \
              "/mnt/d/Ansible/ansible-lamp-wordpress"; do
    [[ -f "${cand}/ansible.cfg" ]] && PROJECT_SRC="${cand}" && break
  done
fi

DEST="${RUN_HOME}/ansible-lamp-wordpress"
if [[ -n "${PROJECT_SRC}" && -d "${PROJECT_SRC}" ]]; then
  echo "Копирую проект из ${PROJECT_SRC} в ${DEST}"
  echo "(работа напрямую из /mnt/d медленная и ломает права файлов — копируем в домашний каталог)"
  mkdir -p "${DEST}"
  rsync -a --delete \
    --exclude '.git' --exclude 'logs/' --exclude '.ansible-salts' \
    "${PROJECT_SRC}/" "${DEST}/"
  chown -R "${RUN_USER}:${RUN_USER}" "${DEST}"
else
  echo "Проект не найден по путям /mnt/d/... — используйте текущий каталог."
  DEST="$(pwd)"
fi

echo
echo "=== 6. Коллекции Ansible ==="
cd "${DEST}"
ansible-galaxy collection install -r requirements.yml -p collections 2>&1 | tail -5 || true

echo
echo "=== 7. Проверки готовности ==="
echo "Python:  $(python3 --version)"
echo "Ansible: $(ansible --version | head -1)"
ansible-galaxy collection list 2>/dev/null | grep -E 'community.(general|mysql)' || \
  echo "ВНИМАНИЕ: коллекции community.general / community.mysql не найдены"
PID1="$(ps -p 1 -o comm=)"
echo "PID 1:   ${PID1}"
if [[ "${PID1}" != "systemd" ]]; then
  echo "systemd не запущен - сервисы будут управляться через sysvinit."
  echo "Убедитесь, что в inventories/wsl/group_vars/lamp.yml задано: service_use: sysvinit"
fi

cat <<EOF

========================================================================
  ГОТОВО. Запуск развёртывания (от обычного пользователя ${RUN_USER}):

      cd ${DEST}
      ./scripts/deploy.sh wsl site.yml      # лог с шапкой, ping и SERVICE STATE

  Либо напрямую:
      mkdir -p logs
      ansible-playbook -i inventories/wsl playbooks/site.yml \\
        2>&1 | tee logs/wsl-\$(date +%Y%m%d-%H%M%S).log

  Сайт будет доступен из Windows: http://localhost
  Админка:                        http://localhost/wp-admin
      логин: wpadmin   пароль: DevWpAdminPass_2026

  Скопировать лог в Windows:
      cp logs/<файл>.log "/mnt/d/Новая папка/Ansible/ansible-lamp-wordpress/logs/"
========================================================================
EOF
