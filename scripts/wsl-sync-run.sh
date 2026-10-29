#!/usr/bin/env bash
# Синхронизация проекта из /mnt/d в домашний каталог admin и прогон site.yml.
# Запускать от root: wsl.exe -d Debian -u root bash /mnt/d/.../wsl-sync-run.sh [purge|keep]
#   purge (по умолчанию) - сначала удалить apache2/mariadb/php, чтобы прогон
#           шёл "с нуля" и был честным;
#   keep  - ничего не удалять, используется для проверки идемпотентности.
set -u

MODE=${1:-purge}
PROJ=/home/admin/ansible-lamp-wordpress

echo "=== 1. Поиск исходников на /mnt/d ==="
SRC=$(find /mnt/d -maxdepth 5 -type d -name ansible-lamp-wordpress 2>/dev/null | head -1)
echo "SRC=$SRC"
[ -n "$SRC" ] || { echo "Исходники не найдены"; exit 1; }

echo "=== 2. Что установлено вручную при диагностике ==="
dpkg -l 'apache2*' 'mariadb*' 'php*' 2>/dev/null | grep '^ii' | awk '{print $2}' | head -30

if [ "$MODE" = "purge" ]; then
  echo "=== 3. Очистка: остановка сервисов и удаление пакетов (честный прогон с нуля) ==="
  # Сервисы останавливаем ДО удаления каталогов данных: без systemd
  # (sysvinit + inbox-WSL) apt не всегда успевает корректно остановить демон,
  # и процесс остаётся работать с уже удалённым datadir - отсюда ошибки вида
  # "Can't create database (errno: 2 No such file or directory)".
  for s in apache2 php8.2-fpm mariadb mysql; do
    service "$s" stop >/dev/null 2>&1 && echo "остановлен: $s"
  done
  pkill -f mariadbd 2>/dev/null; pkill -f mariadbd 2>/dev/null
  sleep 2
  pgrep -a mariadbd || echo "mariadbd не запущен"
  INSTALLED=$(dpkg -l 'apache2*' 'mariadb*' 'php*' 2>/dev/null | grep '^ii' | awk '{print $2}')
  if [ -n "$INSTALLED" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $INSTALLED 2>&1 | tail -5
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -qq 2>&1 | tail -5
  fi
  rm -rf /var/lib/mysql /var/www/wordpress /home/admin/.ansible-salts
else
  echo "=== 3. Режим keep: пакеты и данные не трогаем (проверка идемпотентности) ==="
fi
echo "остатки в /etc/init.d:"; ls /etc/init.d/

echo "=== 4. Синхронизация проекта ==="
mkdir -p "$PROJ"
rsync -a --delete \
  --exclude '.git' \
  --exclude 'logs/' \
  --exclude '.ansible-salts' \
  --exclude 'collections/ansible_collections' \
  "$SRC/" "$PROJ/"
mkdir -p "$PROJ/logs"
chown -R admin:admin /home/admin
chmod 755 /home /home/admin
chmod -R go-w "$PROJ"
# Соли, созданные предыдущими прогонами от root, недоступны пользователю -
# lookup('password') пишет их на control node без sudo.
if [ -d /home/admin/.ansible-salts ] && [ "$(stat -c %U /home/admin/.ansible-salts)" != "admin" ]; then
  echo "переприсваиваю .ansible-salts пользователю admin"
  chown -R admin:admin /home/admin/.ansible-salts
fi
echo "файлов: $(find "$PROJ" -type f | wc -l)"

echo "=== 5. Проверка ключевых правок внутри WSL ==="
grep -n 'service_use' "$PROJ/inventories/wsl/group_vars/lamp.yml" | head -3
grep -c 'use: "{{ service_use' "$PROJ/roles/mysql/tasks/main.yml" "$PROJ/roles/mysql/handlers/main.yml"

echo "=== 6. Прогон site.yml ==="
cd "$PROJ" || exit 1
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$PROJ/logs/wsl-$STAMP.log"
echo "LOG=$LOG"
runuser -u admin -- env PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/admin \
  ansible-playbook -i inventories/wsl playbooks/site.yml \
  --diff > "$LOG" 2>&1
RC=$?
echo "=== exit code: $RC ==="
tail -40 "$LOG"
echo "$LOG" > /tmp/last-run-log-path
