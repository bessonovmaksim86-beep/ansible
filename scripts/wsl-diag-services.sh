#!/usr/bin/env bash
# Проверка содержимого пакета php8.2-fpm БЕЗ установки + коллекция ansible.posix.
cd /tmp || exit 1
rm -f php8.2-fpm_*.deb
apt-get download php8.2-fpm >/dev/null 2>&1 && echo "скачано: $(ls php8.2-fpm_*.deb)"
echo
echo "=== init.d / systemd в пакете ==="
dpkg -c php8.2-fpm_*.deb 2>/dev/null | grep -E "init.d|systemd/system|sbin/php-fpm" | head -8
echo
echo "=== conffiles ==="
dpkg -c php8.2-fpm_*.deb 2>/dev/null | grep -cE "." | xargs echo "всего файлов в пакете:"
rm -f php8.2-fpm_*.deb

echo
echo "=== apache2: есть ли init.d ==="
dpkg -L apache2 2>/dev/null | grep "init.d" | head -2 || echo "apache2 не установлен"

echo
echo "=== коллекция ansible.posix (для callback profile_tasks/timer) ==="
cd /home/admin/ansible-lamp-wordpress && \
  runuser -u admin -- ansible-galaxy collection install ansible.posix -p collections 2>&1 | tail -2
