# Ansible Homelab Project

Автоматическое развертывание homelab из 5 виртуальных машин (проект `al-kv`).

## Стек
- **vm-ctrl** (192.168.1.131): Ansible, Prometheus, Grafana, Alertmanager, Loki, Promtail
- **vm-web** (192.168.1.82): Nginx, node_exporter, promtail, Docker
- **vm-dns** (192.168.1.94): Pi-hole в Docker, node_exporter, promtail
- **vm-vpn** (192.168.1.77): WireGuard, node_exporter, promtail
- **vm-legacy** (192.168.1.62): Nginx (SELinux), dnf-automatic, node_exporter, promtail

## Как запустить у себя (Prerequisites)

⚠️ **Внимание:** Репозиторий содержит зашифрованные секреты (Ansible Vault) и настроен под конкретную локальную сеть. Чтобы запустить его у себя, выполните шаги:

### 1. Подготовка окружения
У вас должны быть 5 виртуальных машин с ОС Ubuntu/Debian/Rocky, доступные по SSH.
Отредактируйте файл `inventory/hosts`, указав **свои** IP-адреса и имена пользователей (в репозитории указаны IP `192.168.1.x` и юзеры `admin`, `admin1`, `student`).

Убедитесь, что вы можете зайти на каждую машину по SSH-ключу без пароля.

### 2. Настройка Ansible Vault
Вам нужно создать свой файл с паролем и зашифровать свои секреты:
```bash
echo "ваш_пароль" > .vault_pass
chmod 600 .vault_pass
ansible-vault create inventory/group_vars/all/vault.yml
