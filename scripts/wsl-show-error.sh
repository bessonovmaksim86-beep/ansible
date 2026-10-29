#!/usr/bin/env bash
# Показывает фрагмент лога с первой фатальной ошибкой.
LOG=$(cat /tmp/last-run-log-path 2>/dev/null)
echo "LOG=$LOG"
grep -n "fatal:" "$LOG" | head -3
N=$(grep -n "fatal:" "$LOG" | head -1 | cut -d: -f1)
if [ -n "$N" ]; then
  START=$(( N > 25 ? N - 25 : 1 ))
  sed -n "${START},$(( N + 20 ))p" "$LOG"
else
  echo "fatal не найден; последние 40 строк:"; tail -40 "$LOG"
fi
