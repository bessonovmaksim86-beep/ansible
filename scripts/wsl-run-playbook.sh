#!/usr/bin/env bash
# Прогон отдельного плейбука (по умолчанию lamp.yml) после синхронизации проекта.
set -u
PB=${1:-lamp.yml}
SRC=$(find /mnt/d -maxdepth 5 -type d -name ansible-lamp-wordpress 2>/dev/null | head -1)
PROJ=/home/admin/ansible-lamp-wordpress
[ -n "$SRC" ] || { echo "Исходники не найдены"; exit 1; }
rsync -a --delete --exclude '.git' --exclude 'logs/' --exclude '.ansible-salts' \
  --exclude 'collections/ansible_collections' "$SRC/" "$PROJ/"
chown -R admin:admin /home/admin
chmod -R go-w "$PROJ"
cd "$PROJ" || exit 1
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$PROJ/logs/wsl-$STAMP-$PB"
runuser -u admin -- env PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/admin \
  ansible-playbook -i inventories/wsl "playbooks/$PB" > "$LOG" 2>&1
echo "=== exit: $? ==="
tail -25 "$LOG"
