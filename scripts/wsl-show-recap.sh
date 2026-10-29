#!/usr/bin/env bash
# Показывает RECAP последнего лога указанного плейбука и блок самопроверки.
PB=${1:-lamp.yml}
L=$(ls -t "/home/admin/ansible-lamp-wordpress/logs/"wsl-*"$PB" 2>/dev/null | head -1)
echo "LOG=$L"
[ -n "$L" ] || exit 1
grep -E "PLAY RECAP" -A 2 "$L"
echo "--- self-check ---"
grep -E "Apache:|PHP-FPM:|MariaDB:" "$L" | head -6
