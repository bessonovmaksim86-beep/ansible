# Развёртывание в WSL2: Debian как целевой хост

Вариант для случая, когда внешней Debian-ВМ нет: целевая система поднимается
локально в WSL2, Ansible исполняет плейбук внутри этого же Debian
(`ansible_connection: local`, привилегии — через `sudo NOPASSWD`).
Все роли и плейбуки используются без изменений — меняется только инвентарь
(`inventories/wsl/`) и набор переменных (отключены `ufw`/`fail2ban`, сайт
доступен как `http://localhost`).

---

## Шаг 0. Обязательное условие: виртуализация в BIOS

WSL2 не запустится без аппаратной виртуализации. На этой машине при диагностике
выяснено (окт. 2026):

| Проверка | Значение |
|---|---|
| Компонент `Microsoft-Windows-Subsystem-Linux` | Disabled (включим скриптом) |
| Компонент `VirtualMachinePlatform` | Disabled (включим скриптом) |
| Гипервизор (`HypervisorPresent`) | False |
| **`VirtualizationFirmwareEnabled` (SVM в BIOS)** | **False — включить можно только из BIOS** |
| Поддержка SVM/SLAT процессором (AMD Ryzen 3 1200) | True — железо готово |
| Windows 10 Pro 21H2 (19044), права администратора | OK, WSL2 поддерживается |

**Как включить SVM (AMD Ryzen):**

1. Перезагрузка → вход в BIOS/UEFI: `DEL` (иногда `F2`) при появлении логотипа.
2. Найти переключатель виртуализации:
   * AMI/Aptio, ASUS: `Advanced → CPU Configuration → SVM Mode → Enabled`
   * Gigabyte: `M.I.T / Tweaker → Advanced CPU Settings → SVM Mode → Enabled`
   * MSI: `OC → CPU Features → SVM Mode → Enabled`
   * (на Intel этот же пункт называется `Intel Virtualization Technology / VT-x`)
3. `F10` — сохранить и выйти.

Проверка после загрузки Windows (PowerShell):

```powershell
(Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled   # должно быть True
(Get-CimInstance Win32_ComputerSystem).HypervisorPresent          # станет True после включения WSL
```

## Шаг 1. Включение WSL2 и установка Debian

PowerShell **от администратора**:

```powershell
cd "D:\Новая папка\Ansible\ansible-lamp-wordpress"
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\enable-wsl2.ps1
```

Скрипт: проверит SVM (и подскажет, что делать), включит
`Microsoft-Windows-Subsystem-Linux` + `VirtualMachinePlatform`, выставит
WSL 2 по умолчанию, выполнит `wsl --update` и установит дистрибутив Debian.

Если автоматическая установка не удалась (нет доступа к Store) — ставлю вручную:

```powershell
wsl --install -d Debian            # или: winget install Debian.Debian
wsl --set-default-version 2
```

**Обязательно перезагрузить компьютер** после включения компонентов.

Затем запустить **Debian** из меню Пуск: при первом старте попросит создать
пользователя и пароль — это и будет пользователь для Ansible (первый
пользователь в WSL автоматически состоит в `sudo`).

## Шаг 1.5. Ограничение inbox-WSL: вместо systemd работает sysvinit

На Windows 10 21H2 (build 19044) доступен только «встроенный» WSL поколения
2021 года с ядром `5.10.16.3-microsoft-standard-WSL2`. Он **не поднимает
systemd как PID 1**, даже если в `/etc/wsl.conf` стоит `[boot] systemd=true`, а
пакеты systemd установлены:

```bash
ps -p 1 -o comm=              # /init, а не systemd
ls /run/systemd/system        # No such file or directory
systemctl is-active apache2   # Failed to connect to bus: No such file or directory
```

Современные сборки WSL (2.x/3.x), где `systemd=true` действительно работает,
требуют Windows 11 — обновление ОС в рамках этого проекта недоступно.

Сервисы поднимаются штатными средствами Debian через **sysvinit**:

```bash
service apache2 start && curl -I http://127.0.0.1/    # HTTP 200
service mariadb start && pgrep -a mariadbd            # демон запущен
ls /etc/init.d/                                       # apache2, mariadb, php8.2-fpm, cron
```

**Последствие для Ansible.** Установленные пакеты systemd ломают
автоопределение: `ansible_service_mgr` возвращает `systemd`, и
`ansible.builtin.service` падает с «Service is in unknown state». Поэтому
менеджер сервисов задаётся явной переменной во всех задачах и handlers:

```yaml
# roles/*/tasks/main.yml, roles/*/handlers/main.yml
- name: MySQL | Ensure MariaDB is started and enabled
  ansible.builtin.service:
    use: "{{ service_use | default(omit) }}"   # omit => автоопределение
```

```yaml
# inventories/wsl/group_vars/lamp.yml
service_use: sysvinit
```

На обычных Debian-хостах (dev/prod) переменную задавать **не нужно**:
`default(omit)` возвращает управление автоопределению, и там работает systemd.
По той же причине роль `common` выставляет часовой пояс через `/etc/timezone` +
`dpkg-reconfigure tzdata`, а не через `timedatectl`/`community.general.timezone`
(без systemd недоступно), а `playbooks/lamp.yml` проверяет работоспособность
PHP-FPM по доступности unix-сокета пула (`wait_for`), а не по
`systemctl is-active` — такой способ проверки одинаково работает и с systemd,
и с sysvinit.

## Шаг 2. Подготовка Debian внутри WSL

Открыть Debian и выполнить (путь к проекту на диске `D:` монтируется как `/mnt/d`):

```bash
sudo bash "/mnt/d/Новая папка/Ansible/ansible-lamp-wordpress/scripts/setup-wsl-debian.sh"
```

Скрипт делает: ставит `python3`, `python3-pymysql`, `sudo`, `rsync`, `cron`,
`locales`, выдаёт `sudo NOPASSWD`, ставит `ansible-core` в venv
`/opt/ansible-venv` (символические ссылки в `/usr/local/bin`), копирует проект
из `/mnt/d/...` в `~/ansible-lamp-wordpress` и ставит коллекции из
`requirements.yml`.

Проверки готовности внутри Debian:

```bash
python3 --version           # Python 3.11.x
ansible --version           # ansible-core 2.19.x
service apache2 status      # работает через sysvinit
```

### Если дистрибутив ставился без доступа к Microsoft Store

`snap`/`wsl --install -d Debian` в этой среде завершился ошибкой `0x80072ee7`
(сбой обращения к Store), поэтому Debian 12.15 собран вручную:

1. образ корневой ФС взят из реестра Docker Hub
   (`library/debian:bookworm`) и сохранён как tar-архив;
2. обновление ядра WSL — `wsl_update_x64.msi` с
   `wslstorestorage.blob.core.windows.net`, установка `msiexec /quiet`;
3. импорт: `wsl --import Debian C:\WSL\Debian <rootfs>.tar.gz --version 2`;
4. базовая настройка: `scripts/provision-wsl-rootfs.sh` (пользователь `admin`,
   `sudo NOPASSWD`, `/etc/wsl.conf`).

Образ cloud-издания (`debian-12-generic-amd64.tar.xz`) для `wsl --import` **не
пригоден**: внутри него `disk.raw`, а не корневая файловая система.

## Шаг 3. Прогон сценария и запись лога

Рекомендуется обёртка `deploy.sh` — она пишет в один файл шапку (версия
Ansible, дата, команда), результат `--syntax-check`, `ping`, полный вывод
плейбука и блок `SERVICE STATE`:

```bash
cd ~/ansible-lamp-wordpress
./scripts/deploy.sh wsl site.yml
```

Ручной вариант:

```bash
ansible-playbook -i inventories/wsl playbooks/site.yml --syntax-check
ansible -i inventories/wsl all -m ping
mkdir -p logs
ansible-playbook -i inventories/wsl playbooks/site.yml \
  2>&1 | tee logs/wsl-$(date +%Y%m%d-%H%M%S).log
```

Фактический результат этого прогона (Debian 12.15, ansible-core 2.19.14,
первый запуск на чистую систему):

```
PLAY RECAP *********************************************************************
wp-wsl : ok=78  changed=26  unreachable=0  failed=0  skipped=26  rescued=0  ignored=0
```

## Шаг 4. Проверка результата

Из **Windows**, браузером:

* сайт — `http://localhost` (в WSL2 с NAT-сетью порт 80 пробрасывается на
  `localhost` автоматически);
* админка — `http://localhost/wp-admin`, логин `wpadmin`,
  пароль `DevWpAdminPass_2026`
  (`inventories/wsl/group_vars/all/vault.yml`).

Из **Debian** (в inbox-WSL — через `service`, а не `systemctl`):

```bash
service apache2 status && service php8.2-fpm status && service mariadb status
pgrep -a mariadbd | head -1
apache2ctl configtest
php-fpm8.2 -t
mariadb -e "SHOW DATABASES; SHOW GRANTS FOR 'wpuser'@'localhost';"
wp core version --allow-root --path=/var/www/wordpress
wp user list --allow-root --path=/var/www/wordpress --fields=user_login,roles
curl -I http://127.0.0.1/
```

Идемпотентность — повторный прогон даёт `changed=0`:

```bash
./scripts/deploy.sh wsl site.yml
# wp-wsl : ok=71  changed=0  unreachable=0  failed=0  skipped=30
```

## Шаг 5. Перенос лога в Windows и отправка на проверку

```bash
cp logs/*-wsl-site.log "/mnt/d/Новая папка/Ansible/ansible-lamp-wordpress/logs/"
```

Далее в Git Bash на Windows:

```bash
cd "/d/Новая папка/Ansible/ansible-lamp-wordpress"
git init && git add . && git commit -m "Ansible LAMP + WordPress: roles, playbook, WSL2 log"
git add -f logs/wsl-<_stamp_>.log && git commit -m "Add deployment log"
git remote add origin git@github.com:<логин>/ansible-lamp-wordpress.git
git push -u origin main
```

---

## Частые проблемы WSL2

| Симптом | Причина и решение |
|---|---|
| `Wsl/Service/CreateInstance/E_ACCESSDENIED` или «гипервизор не найден» | SVM не включён в BIOS / не было перезагрузки после включения компонентов |
| `systemctl` ругается «Failed to connect to bus» / «System has not been booted with systemd» | в inbox-WSL (ядро 5.10) systemd не поднимается вообще — см. шаг 1.5: работать через `service` и `service_use: sysvinit` |
| `Service is in unknown state` в задаче `ansible.builtin.service` | `ansible_service_mgr` ошибочно определяет systemd (пакеты установлены). Проверить `inventories/wsl/group_vars/lamp.yml` — там должен быть `service_use: sysvinit` |
| `timedatectl` или `community.general.timezone` падают | нет systemd: роль `common` пишет `/etc/timezone` и выполняет `dpkg-reconfigure --frontend noninteractive tzdata` |
| `Can't create database wordpress (errno: 2 "No such file or directory")` | демон MariaDB остался работать с удалённым datadir после ручной чистки. Останавливать сервисы **до** удаления `/var/lib/mysql` (в `wsl-sync-run.sh` это учтено) |
| `The lookup plugin 'password' failed: Permission denied` при подготовке солей | каталог `.ansible-salts` создан с `become: true` и принадлежит root. lookup выполняется на управляющем узле без sudo, поэтому задача создания каталога идёт с `become: false` |
| `wsl --install` ничего не ставит (`0x80072ee7`) | нет доступа к Microsoft Store: импортировать rootfs вручную через `wsl --import`, см. шаг 2 |
| `Failed to connect to the host via ssh` | не тот инвентарь: для локального прогона нужен `-i inventories/wsl` (там `ansible_connection: local`, SSH не используется) |
| `module not found: community.mysql` | коллекции ставятся в `./collections` внутри скопированного проекта; выполнить `ansible-galaxy collection install -r requirements.yml -p collections` из каталога проекта |
| `apt` долго работает / ошибки прав при запуске из `/mnt/d` | поэтому проект копируется в `~`: файловая система `/mnt/d` медленная и не хранит unix-права |
| `http://localhost` не открывается из Windows | WSL «уснул»: выполнить `wsl hostname -I` или открыть сайт сразу после прогона; при использовании `apache_enable_ssl: true` идти на `https://localhost` |
| Порт 80 занят IIS/другим сервисом Windows | сменить `apache_vhost_port` (например 8080) в `inventories/wsl/group_vars/lamp.yml` и прогнать роль `apache` |
| Время на хосте «съехало» после сна Windows | в WSL время синхронизируется автоматически; при необходимости `sudo hwclock -s` |

## Отличие этого прогона от «боевого» сценария

Лог, полученный в WSL2, демонстрирует работу всех ролей и плейбука, но
отличается от развёртывания на отдельной ВМ: подключение `local` вместо SSH,
`ufw`/`fail2ban` отключены, адрес сайта `localhost`. При появлении реальной
ВМ достаточно: `bootstrap-host.sh` → вписать адрес в `inventories/dev/hosts.yml`
→ `./scripts/deploy.sh dev site.yml`.
