# RUNBOOK: развёртывание WordPress на чистом Debian-хосте

Документ описывает **фактическую последовательность моих действий** при
применении сценария. Адрес хоста мне уже известен — я получил его сразу после
создания виртуальной машины в облаке (в примере используется `192.168.56.10`,
в реальном прогоне подставляется адрес вашей ВМ).

Управляющий узел: Linux/WSL с установленным Ansible (`ansible-core 2.16`),
на целевом хосте — чистая Debian 12 «netinst» без каких-либо пакетов LAMP.

---

## Шаг 0. Проверка управляющего узла (один раз)

```bash
ansible --version          # убедился, что ansible-core >= 2.14
cd ~/ansible-lamp-wordpress
ansible-galaxy collection install -r requirements.yml -p collections
```

Установились `community.general` (нужна для `ufw`, `apache2_module`,
`timezone`, `locale_gen`) и `community.mysql` (нужна для `mysql_db`,
`mysql_user`, `mysql_query`). Без второй роль `mysql` падает на
`module not found`, поэтому проверяю это до основного прогона.

## Шаг 1. Добавил хост в инвентарь

Правлю `inventories/dev/hosts.yml` — вписал адрес полученной ВМ:

```yaml
webservers:
  hosts:
    wp01:
      ansible_host: 192.168.56.10     # <-- адрес из панели облака
dbservers:
  hosts:
    wp01:
```

В `inventories/dev/host_vars/wp01.yml` задал публичный адрес сайта и имя
виртуального хоста:

```yaml
wordpress_site_url: "http://192.168.56.10"
apache_server_name: wp.local
wordpress_env_type: development
```

Можно было поступить проще и не править файл — в инвентаре есть плоский
`inventories/hosts.ini`, а `deploy.sh` умеет переопределять адрес переменной
окружения: `WP_HOST=1.2.3.4 ./scripts/deploy.sh`. Я выбрал явный вариант с
`host_vars`, чтобы адрес был зафиксирован в репозитории и его видел ревьюер.

## Шаг 2. Подготовка доступа к чистому хосту

Захожу на ВМ под тем пользователем, которого дало облако (обычно `root`),
и запускаю подготовительный скрипт — он ставит мой публичный ключ, создаёт
пользователя `admin` с `sudo NOPASSWD` и ставит `python3` (без интерпретатора
Python Ansible не работает):

```bash
export TARGET_HOST=192.168.56.10
export TARGET_USER=root
./scripts/bootstrap-host.sh
```

Эквивалент ручными командами, если скрипта нет под рукой:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
ssh-copy-id root@192.168.56.10
ssh root@192.168.56.10 '
  useradd -m -s /bin/bash admin
  install -d -m 700 -o admin -g admin /home/admin/.ssh
  echo "<содержимое id_ed25519.pub>" >> /home/admin/.ssh/authorized_keys
  chmod 600 /home/admin/.ssh/authorized_keys; chown -R admin:admin /home/admin/.ssh
  echo "admin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-admin; chmod 440 /etc/sudoers.d/90-admin
  apt-get update && apt-get install -y sudo python3 openssh-server'
```

## Шаг 3. Проверил доступность и синтаксис

```bash
ansible -i inventories/dev all -m ping
# wp01 | SUCCESS => {"changed": false, "ping": "pong"}

ansible-playbook -i inventories/dev playbooks/site.yml --syntax-check
# playbook: playbooks/site.yml          (без ошибок — синтаксис ок)
```

`ping` первым делом подтверждает три вещи: ключ подходит, `sudo` работает без
пароля, на хосте есть `/usr/bin/python3`.

## Шаг 4. Запустил сценарий и сохранил лог

Основной запуск — через обёртку, которая пишет весь вывод в файл:

```bash
./scripts/deploy.sh dev site.yml
# лог: logs/20261029-142311-dev-site.log
```

Та же команда «в лоб», со всеми ключами, которые реально использовались:

```bash
ansible-playbook \
  --inventory inventories/dev \
  --become \
  --become-method=sudo \
  --become-user=root \
  --forks 10 \
  --timeout 30 \
  playbooks/site.yml \
  2>&1 | tee logs/deploy-$(date +%Y%m%d-%H%M%S).log
```

Расшифровка ключей:

| Ключ | Зачем |
|---|---|
| `-i inventories/dev` | взять инвентарь из каталога dev (там `hosts.yml` + `group_vars` + `host_vars`) |
| `--become`, `--become-method=sudo`, `--become-user=root` | все задачи ставятся от root через sudo (дублируют `ansible.cfg`, но в команде я их держу явно) |
| `--forks 10` | параллельность (на одном хосте не критично, полезно при росте инвентаря) |
| `--timeout 30` | таймаут SSH-соединения |
| `2>&1 \| tee …` | писать и в консоль, и в файл лога — лог нужен для проверки |

Прогон «на сухую» перед боем (полезно, если хост уже не совсем чистый):

```bash
ansible-playbook -i inventories/dev playbooks/site.yml --check --diff
```

Прочие варианты, которые я использовал при отладке ролей по отдельности:

```bash
ansible-playbook -i inventories/dev playbooks/lamp.yml                 # только Apache+PHP+MariaDB
ansible-playbook -i inventories/dev playbooks/wordpress.yml            # только CMS
ansible-playbook -i inventories/dev playbooks/site.yml --tags apache   # одна роль
ansible-playbook -i inventories/dev playbooks/site.yml --start-at-task="WordPress | Run the installer (wp core install)"
ansible-playbook -i inventories/dev playbooks/site.yml --limit wp01    # один хост
ansible-playbook -i inventories/dev playbooks/site.yml -vvv            # подробный вывод в лог
```

## Шаг 5. Развёртывание production-окружения (с шифрованными секретами)

Для прод-инвентаря пароли не хранятся в открытом виде, поэтому добавляется
работа с vault и ключ `--ask-vault-pass` (или `--vault-password-file`):

```bash
ansible-vault create inventories/prod/group_vars/all/vault.yml
# внутри:
#   mysql_root_password: "..."
#   mysql_wpuser_password: "..."
#   wordpress_admin_password: "..."

ansible-playbook -i inventories/prod playbooks/site.yml \
  --ask-vault-pass --diff --limit wp-prod-01 2>&1 | tee logs/prod-$(date +%Y%m%d).log

# без интерактивного ввода пароля:
ansible-playbook -i inventories/prod playbooks/site.yml \
  --vault-password-file ~/.vault_pass --diff
```

## Шаг 6. Проверка результата

Что я смотрел после завершения прогона (вывод тоже уходит в лог):

```bash
ssh admin@192.168.56.10 '
  systemctl is-active apache2 php8.2-fpm mariadb
  apache2ctl configtest
  php-fpm8.2 -t
  mysql -e "SHOW DATABASES; SHOW GRANTS FOR '"'"'wpuser'"'"'@'"'"'localhost'"'"';"
  wp core version --path=/var/www/wordpress --allow-root
  wp plugin list --path=/var/www/wordpress --allow-root'

curl -I http://192.168.56.10/            # ожидаю 200
curl -sI http://192.168.56.10/wp-login.php | head -1
```

В браузере: главная страница сайта и вход в `http://192.168.56.10/wp-admin/`
под `wpadmin` (пароль — из `inventories/dev/group_vars/all/vault.yml`).

Повторный запуск того же плейбука — проверка идемпотентности: в логе должно
быть `changed=0` (или 1–2 задачи на перезагрузку конфигов), ошибок нет.

```bash
ansible-playbook -i inventories/dev playbooks/site.yml 2>&1 | tee -a logs/idempotency.log
```

## Шаг 7. Зафиксировал лог и отправил проект на проверку

```bash
git init
git add .
git commit -m "Ansible roles + playbook: LAMP & WordPress on Debian"
git remote add origin git@github.com:<user>/ansible-lamp-wordpress.git
git push -u origin main

# лог прогона кладу в репозиторий принудительно (каталог logs/ в .gitignore)
cp logs/20261029-142311-dev-site.log logs/deploy-20261029.log.example
git add -f logs/deploy-20261029.log.example
git commit -m "Add deployment log" && git push
```

Ссылка на репозиторий (проект + лог + этот RUNBOOK) передаётся ментору.

---

## Типичные проблемы и что делать

| Симптом | Причина / решение |
|---|---|
| `Failed to connect to the host via ssh: ... Permission denied (publickey)` | ключ не скопирован / не тот пользователь → повторить Шаг 2, проверить `ansible_user` |
| `module not found: community.mysql` | не установлены коллекции → `ansible-galaxy collection install -r requirements.yml -p collections` |
| `Could not find imported module support code for mysql_db` | на хосте нет `python3-pymysql` → роль ставит его сама; при `--check` прогон пропускается, запускать без `--check` |
| `Access denied for user 'root'@'localhost'` после смены пароля | роль сохранила вход по unix-socket; креды лежат в `/root/.my.cnf`, проверять от sudo |
| Apache отдаёт 403 на сайте | права на `/var/www/wordpress` → повторно прогнать роль `wordpress` (задачи с `recurse: true`) |
| Белый экран / 500 | смотреть `/var/log/apache2/wordpress-error.log` и `/var/log/php8.2-fpm-www.log`; чаще всего не хватает PHP-расширения из `php_fpm_extra_packages` |
| `ufw` отрезал SSH | правило `OpenSSH` добавляется до включения файрвола; при случайной блокировке — консоль облачного провайдера и `ufw disable` |
| Сайт открывается по IP, но админка уходит на старый хост | сменить `wordpress_site_url` и прогнать роль ещё раз (она обновит `wp option update`) |
