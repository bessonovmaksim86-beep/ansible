#!/usr/bin/env bash
# Отчётный прогон через scripts/deploy.sh (с шапкой, syntax-check, ping,
# SERVICE STATE) и перенос лога на диск Windows.
#   wsl.exe -d Debian -u root bash /mnt/d/.../scripts/wsl-report-run.sh [purge|keep]
set -u
MODE=${1:-keep}
SRC=$(find /mnt/d -maxdepth 5 -type d -name ansible-lamp-wordpress 2>/dev/null | head -1)
PROJ=/home/admin/ansible-lamp-wordpress
[ -n "$SRC" ] || { echo "Исходники на /mnt/d не найдены"; exit 1; }

if [ "$MODE" = "purge" ]; then
  for s in apache2 php8.2-fpm mariadb mysql; do service "$s" stop >/dev/null 2>&1; done
  pkill -f mariadbd 2>/dev/null; sleep 2
  INSTALLED=$(dpkg -l 'apache2*' 'mariadb*' 'php*' 2>/dev/null | grep '^ii' | awk '{print $2}')
  [ -n "$INSTALLED" ] && {
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $INSTALLED >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -qq >/dev/null 2>&1
  }
  rm -rf /var/lib/mysql /var/www/wordpress /home/admin/.ansible-salts
fi

rsync -a --delete --exclude '.git' --exclude 'logs/' --exclude '.ansible-salts' \
  --exclude 'collections/ansible_collections' "$SRC/" "$PROJ/"
mkdir -p "$PROJ/logs"
chown -R admin:admin /home/admin
chmod 755 /home /home/admin
chmod -R go-w "$PROJ"

cd "$PROJ" || exit 1
runuser -u admin -- env PATH=/usr/local/bin:/usr/bin:/bin HOME=/home/admin TERM=dumb \
  bash ./scripts/deploy.sh wsl site.yml 2>&1 | tail -25

LAST=$(ls -t "$PROJ"/logs/*-wsl-site.log 2>/dev/null | head -1)
echo "LAST=$LAST"
[ -n "$LAST" ] && cp -v "$LAST" "$SRC/logs/"
echo "$LAST" > /tmp/last-run-log-path
