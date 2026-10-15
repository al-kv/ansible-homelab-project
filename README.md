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
