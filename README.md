# Ansible Homelab — Блок 2

Развёртывание homelab из 5 виртуальных машин через Ansible.

## Что разворачивается

| VM | ОС | Роль |
|---|---|---|
| vm-ctrl | Ubuntu 24.04 | Ansible, Prometheus, Grafana, Loki, Alertmanager |
| vm-web | Ubuntu 24.04 | Nginx, node_exporter, promtail |
| vm-dns | Ubuntu 24.04 | Pi-hole в Docker, node_exporter, promtail |
| vm-vpn | Debian 13 | WireGuard, node_exporter, promtail |
| vm-legacy | Rocky 9 | Nginx, node_exporter, promtail |

## Структура

    ansible_project_lab/
    ├── ansible.cfg
    ├── inventory/hosts
    ├── inventory/group_vars/all/
    │   ├── vars.yml
    │   └── vault.yml
    ├── playbooks/site.yml
    ├── roles/
    │   ├── common/
    │   ├── docker/
    │   ├── nginx/
    │   ├── node_exporter/
    │   ├── promtail/
    │   ├── wireguard/
    │   ├── pihole/
    │   ├── unattended_upgrades/
    │   └── monitoring_stack/
    └── .github/workflows/ci.yml

## Установка

    sudo apt install pipx
    pipx install --include-deps ansible
    pipx ensurepath
    source ~/.bashrc

    pipx install ansible-scaffold
    mkdir ~/ansible_project_lab && cd ~/ansible_project_lab
    ansible-scaffold . -d site --no-prompt

    printf 'твой-пароль-vault' > .vault_pass
    chmod 600 .vault_pass
    ansible-vault create inventory/group_vars/all/vault.yml

## Запуск

    ansible all -m ping
    ansible-playbook playbooks/site.yml --check --diff
    ansible-playbook playbooks/site.yml

## Проверка

    ansible-playbook playbooks/site.yml
    # changed=0 на всех машинах

    ssh admin@192.168.1.131 "docker ps"
    # 4 контейнера: prometheus, grafana, alertmanager, loki

    # Grafana: http://192.168.1.131:3000

## Troubleshooting

Основные ошибки и решения — в главе 21 методички.

## Лицензия

MIT

## Адреса сервисов

| Сервис | URL |
|---|---|
| Grafana | http://192.168.1.131:3000 |
| Prometheus | http://192.168.1.131:9090 |
| Alertmanager | http://192.168.1.131:9093 |
| Loki API | http://192.168.1.131:3100 |
| Pi-hole admin | http://192.168.1.94/admin |
| Nginx vm-web | http://192.168.1.82 |
| Nginx vm-legacy | http://192.168.1.62 |

## Проверка идемпотентности

    ansible-playbook playbooks/site.yml    # 1-й прогон
    ansible-playbook playbooks/site.yml    # 2-й → changed=0 на всех VM

## Проверка состояния

    ansible all -m shell -a "systemctl is-active node_exporter promtail chrony auditd fail2ban" --become
    curl -s http://192.168.1.131:9090/api/v1/targets | jq '.data.activeTargets[] | {instance: .labels.instance, health}'
    ansible vm-ctrl -m shell -a "docker ps" --become
    ansible vm-dns  -m shell -a "docker ps" --become
