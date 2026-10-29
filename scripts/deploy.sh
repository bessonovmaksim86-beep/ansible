#!/usr/bin/env bash
#
# deploy.sh — запуск Ansible-сценария с обязательным сохранением лога.
#
#   ./scripts/deploy.sh                                   # dev, site.yml
#   ./scripts/deploy.sh dev site.yml
#   ./scripts/deploy.sh prod site.yml --ask-vault-pass
#   ./scripts/deploy.sh dev lamp.yml --check --diff
#   ./scripts/deploy.sh dev site.yml --limit wp01
#   WP_HOST=1.2.3.4 ./scripts/deploy.sh                   # переопределить адрес хоста
#
set -uo pipefail

# --- Каталог проекта (работает при вызове из любой точки) ---
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"

ENVIRONMENT="${1:-dev}"; [[ $# -ge 1 ]] && shift
PLAYBOOK="${1:-site.yml}"; [[ $# -ge 1 ]] && shift
EXTRA_ARGS=("$@")
case "${PLAYBOOK}" in
  *.yml) : ;;
  *) PLAYBOOK="${PLAYBOOK}.yml" ;;
esac

INVENTORY="${INVENTORY:-inventories/${ENVIRONMENT}}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# --- SSH-ключ: добавляем в агент, если он ещё не загружен ---
if [[ -f "${SSH_KEY}" ]] && command -v ssh-add >/dev/null 2>&1; then
  ssh-add -l >/dev/null 2>&1 || ssh-add "${SSH_KEY}" 2>/dev/null || true
fi

# --- Проверка зависимостей ---
for cmd in ansible ansible-playbook ansible-galaxy; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ОШИБКА: ${cmd} не найден. Установите Ansible:" >&2
    echo "  python3 -m pip install --user ansible    # либо: sudo apt install ansible" >&2
    exit 1
  fi
done

# --- Коллекции community.general / community.mysql ---
if ! ansible-galaxy collection list community.general --collections-path collections >/dev/null 2>&1 \
   || ! ansible-galaxy collection list community.mysql --collections-path collections >/dev/null 2>&1; then
  echo ">>> Устанавливаю коллекции из requirements.yml ..."
  ansible-galaxy collection install -r requirements.yml -p collections
fi

# --- Файл лога ---
mkdir -p logs
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="logs/${TIMESTAMP}-${ENVIRONMENT}-${PLAYBOOK%.yml}.log"

# --- Опциональное переопределение адреса хоста из окружения ---
EXTRA_VARS=()
if [[ -n "${WP_HOST:-}" ]]; then
  EXTRA_VARS+=(-e "ansible_host=${WP_HOST}" -e "wordpress_site_url=http://${WP_HOST}")
fi

# --- Шапка лога: версия Ansible, дата, параметры запуска ---
{
  echo "==============================================================="
  echo " Проект    : $(basename "${PROJECT_DIR}")"
  echo " Окружение : ${ENVIRONMENT}   (inventory: ${INVENTORY})"
  echo " Сценарий  : playbooks/${PLAYBOOK}"
  echo " Лог       : ${LOG_FILE}"
  echo " Доп. ключи: ${EXTRA_ARGS[*]:-<нет>} ${EXTRA_VARS[*]:-}"
  echo " Ansible   : $(ansible --version | head -1)"
  echo " Запуск    : $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "==============================================================="
} | tee "${LOG_FILE}"

# --- Проверка синтаксиса ---
echo ">>> ansible-playbook --syntax-check"
ansible-playbook -i "${INVENTORY}" "playbooks/${PLAYBOOK}" --syntax-check | tee -a "${LOG_FILE}"

# --- Проверка доступности хоста ---
echo ">>> ping инвентаря"
ansible -i "${INVENTORY}" lamp -m ping | tee -a "${LOG_FILE}"

# --- Основной запуск: stdout+stderr и в терминал, и в лог ---
echo ">>> запуск playbooks/${PLAYBOOK}"
ANSIBLE_STDOUT_CALLBACK=default \
ANSIBLE_HOST_KEY_CHECKING=True \
  ansible-playbook \
    -i "${INVENTORY}" \
    "playbooks/${PLAYBOOK}" \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
    ${EXTRA_VARS[@]+"${EXTRA_VARS[@]}"} 2>&1 | tee -a "${LOG_FILE}"
RC="${PIPESTATUS[0]}"

# --- Итоговое состояние сервисов в лог ---
# Проверка работает и на systemd, и на sysvinit (напр. WSL старого поколения):
# сначала пробуем systemctl, при его недоступности - status из /etc/init.d.
{
  echo ""
  echo "==================== SERVICE STATE ============================"
  ansible -i "${INVENTORY}" lamp -m shell -a '
    status_of() {
      if command -v systemctl >/dev/null 2>&1 && systemctl is-active "$1" >/dev/null 2>&1; then
        echo active
      elif [ -x "/etc/init.d/$1" ] && "/etc/init.d/$1" status >/dev/null 2>&1; then
        echo active
      else
        echo inactive
      fi
    }
    for s in apache2 php8.2-fpm mariadb; do printf "%-16s %s\n" "$s" "$(status_of $s)"; done
    echo "--- versions ---"
    apache2 -v | head -1
    php -v | head -1
    mariadb --version
    echo "--- wordpress ---"
    wp core version --path=/var/www/wordpress --allow-root 2>/dev/null || true
  ' 2>&1 || true
  echo "==================== END ======================================"
  echo "Код возврата ansible-playbook: ${RC}"
  echo "Команда: ansible-playbook -i ${INVENTORY} playbooks/${PLAYBOOK} ${EXTRA_ARGS[*]:-} ${EXTRA_VARS[*]:-}"
} | tee -a "${LOG_FILE}"

echo ""
echo "Лог сохранён: ${LOG_FILE}"
exit "${RC}"
