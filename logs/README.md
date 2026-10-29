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

Что должно быть в логе, принимаемом на проверку (всё это `deploy.sh` пишет
автоматически):

1. вывод `ansible --version` и дата запуска (шапка);
2. результат `--syntax-check`;
3. вывод `ansible -i inventories/dev lamp -m ping` (`SUCCESS ... "ping": "pong"`);
4. полный вывод `ansible-playbook` со статистикой `PLAY RECAP`
   (`ok=… changed=… unreachable=0 failed=0 skipped=…`);
5. блок `SERVICE STATE`: `systemctl is-active apache2 php8.2-fpm mariadb`,
   версии Apache/PHP/MariaDB, `wp core version`;
6. строка «Команда: ansible-playbook … » с фактическими ключами запуска.

Перед коммитом убедитесь, что в логе нет паролей: задачи с секретами размечены
`no_log: true`, но при отладке с `-vvv`/`--diff` в лог может попасть содержимое
`wp-config.php` — такую версию коммитить нельзя, прогоните без `--diff`.
