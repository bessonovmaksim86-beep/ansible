# Каталог логов прогонов

`deploy.sh` пишет сюда файлы вида `20261029-142311-dev-site.log`
(формат: `ГГГГММДД-ЧЧМСС-<окружение>-<плейбук>.log`).

Сырые логи игнорируются git'ом. Для передачи на проверку нужный лог копируют
как `.example` или добавляют принудительно:

```bash
cp logs/20261029-142311-dev-site.log logs/deploy-20261029.log.example
git add -f logs/deploy-20261029.log.example
git commit -m "Add deployment log"
```

Отчётные логи этого проекта лежат в репозитории под фиксированными именами
(на них есть прямые ссылки в README):

| Файл | Содержание |
|---|---|
| `deploy-20261029-wsl-install.log` | `site.yml` на чистую Debian 12.15 в WSL2: `ok=78 changed=26 failed=0` |
| `deploy-20261029-wsl-idempotency.log` | повторный прогон того же плейбука: `ok=71 changed=0 failed=0` |

Оба файла добавлены в `.gitignore` исключениями по именам, чтобы случайные
новые прогоны снова не попадали в коммит.

Что должно быть в логе, принимаемом на проверку (всё это `deploy.sh` пишет
автоматически):

1. вывод `ansible --version` и дата запуска (шапка);
2. результат `--syntax-check`;
3. вывод `ansible -i inventories/dev lamp -m ping` (`SUCCESS ... "ping": "pong"`);
4. полный вывод `ansible-playbook` со статистикой `PLAY RECAP`
   (`ok=… changed=… unreachable=0 failed=0 skipped=…`);
5. блок `SERVICE STATE`: состояние `apache2`, `php8.2-fpm`, `mariadb`
   (проверка работает и через systemd, и через sysvinit), версии
   Apache/PHP/MariaDB, `wp core version`;
6. строка «Команда: ansible-playbook … » с фактическими ключами запуска.

Перед коммитом убедитесь, что в логе нет паролей: задачи с секретами размечены
`no_log: true`, но при отладке с `-vvv`/`--diff` в лог может попасть содержимое
`wp-config.php` — такую версию коммитить нельзя, прогоните без `--diff`.
