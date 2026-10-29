#makefile
# Типовые операции проекта Ansible (LAMP + WordPress).
#   make help | make syntax | make ping | make deploy ENV=dev
ENV      ?= dev
INVENTORY?= inventories/$(ENV)
SITE     ?= playbooks/site.yml

.PHONY: help galaxy syntax ping deploy deploy-lamp deploy-wp check vault-edit vault-view logs validate clean

help:
	@echo "make galaxy        - установить коллекции из requirements.yml"
	@echo "make syntax        - ansible-playbook --syntax-check по всем плейбукам"
	@echo "make ping          - проверка доступности хостов inventory"
	@echo "make deploy        - полный прогон site.yml с логом (ENV=dev|prod)"
	@echo "make deploy-lamp   - прогон только lamp.yml (Apache/PHP/MariaDB)"
	@echo "make deploy-wp     - прогон только wordpress.yml"
	@echo "make check         - синтаксис + пинг"
	@echo "make vault-edit    - ansible-vault edit для ENV"
	@echo "make vault-view    - ansible-vault view для ENV"
	@echo "make logs          - последние логи"

galaxy:
	ansible-galaxy collection install -r requirements.yml -p collections

syntax:
	for pb in playbooks/*.yml; do \
	  echo "== $$pb"; ansible-playbook -i $(INVENTORY) $$pb --syntax-check || exit 1; \
	done

ping:
	ansible -i $(INVENTORY) all -m ping

check: syntax ping

deploy:
	bash scripts/deploy.sh $(ENV) site.yml

deploy-lamp:
	bash scripts/deploy.sh $(ENV) lamp.yml

deploy-wp:
	bash scripts/deploy.sh $(ENV) wordpress.yml

deploy-wsl:
	bash scripts/deploy.sh wsl site.yml

wsl-setup:
	@echo "Запустите ВНУТРИ Debian:"
	@echo '  sudo bash "/mnt/d/Новая папка/Ansible/ansible-lamp-wordpress/scripts/setup-wsl-debian.sh"'

vault-edit:
	ansible-vault edit inventories/$(ENV)/group_vars/all/vault.yml

vault-view:
	ansible-vault view inventories/$(ENV)/group_vars/all/vault.yml

logs:
	@ls -1t logs/*.log 2>/dev/null | head -5 || echo "логов пока нет"

validate:
	node scripts/validate-yaml.js .
	node scripts/validate-structure.js .

clean:
	rm -f *.retry
	rm -rf .ansible_facts
