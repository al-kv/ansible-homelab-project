#!/usr/bin/env bash
set -euo pipefail

PROJ="${PWD}"
echo ">>> Проект: $PROJ"
[ -f ansible.cfg ] || { echo "Запусти из корня ansible_project_lab"; exit 1; }

# =============================================================
# 1. РОЛЬ PI-HOLE — очистка systemd-resolved + resolv.conf + verify
# =============================================================
mkdir -p roles/pihole/{tasks,handlers,templates}

cat > roles/pihole/tasks/main.yml <<'YAML'
---
# =============================================================================
# ЭТАП 0. Cleanup: если нативный Pi-hole был установлен — снести
# =============================================================================
- name: Check native pihole-FTL unit
  ansible.builtin.stat:
    path: /etc/systemd/system/pihole-FTL.service
  register: pihole_native_unit

- name: Stop and mask native pihole-FTL
  ansible.builtin.systemd:
    name: pihole-FTL
    state: stopped
    enabled: false
    masked: true
  when: pihole_native_unit.stat.exists
  failed_when: false

# =============================================================================
# ЭТАП 1. Освобождаем порт 53: systemd-resolved
# =============================================================================
- name: Ensure resolved.conf.d directory
  ansible.builtin.file:
    path: /etc/systemd/resolved.conf.d
    state: directory
    mode: '0755'

- name: Disable systemd-resolved DNSStubListener
  ansible.builtin.copy:
    dest: /etc/systemd/resolved.conf.d/99-pihole.conf
    content: |
      [Resolve]
      DNSStubListener=no
    mode: '0644'
  notify: restart systemd-resolved

- name: Flush handlers before resolv.conf rewrite
  ansible.builtin.meta: flush_handlers

# =============================================================================
# ЭТАП 2. /etc/resolv.conf — снять immutable, убрать симлинк, создать файл
# =============================================================================
- name: Remove immutable attr from /etc/resolv.conf
  ansible.builtin.command: chattr -i /etc/resolv.conf
  changed_when: false
  failed_when: false

- name: Stat /etc/resolv.conf
  ansible.builtin.stat:
    path: /etc/resolv.conf
  register: rc

- name: Remove symlink /etc/resolv.conf
  ansible.builtin.file:
    path: /etc/resolv.conf
    state: absent
  when: rc.stat.islnk | default(false)

- name: Write real /etc/resolv.conf
  ansible.builtin.copy:
    dest: /etc/resolv.conf
    content: |
      nameserver 127.0.0.1
    mode: '0644'

# =============================================================================
# ЭТАП 3. Директории, compose, firewall
# =============================================================================
- name: Create pihole directories
  ansible.builtin.file:
    path: "/opt/pihole/{{ item }}"
    state: directory
    mode: '0755'
  loop:
    - etc-pihole
    - etc-dnsmasq.d

- name: Render docker-compose.yml
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: /opt/pihole/docker-compose.yml
    mode: '0644'
  notify: restart pihole

- name: Open Pi-hole ports (Debian)
  community.general.ufw:
    rule: allow
    port: "{{ item.port }}"
    proto: "{{ item.proto }}"
  loop:
    - { port: '53', proto: 'tcp' }
    - { port: '53', proto: 'udp' }
    - { port: '80', proto: 'tcp' }
  when: ansible_os_family == "Debian"

# =============================================================================
# ЭТАП 4. Запуск + ПРОВЕРКА
# =============================================================================
- name: Start Pi-hole stack
  community.docker.docker_compose_v2:
    project_src: /opt/pihole
    state: present

- name: Wait for port 53
  ansible.builtin.wait_for:
    host: 127.0.0.1
    port: 53
    timeout: 60
    state: started

- name: Verify DNS through Pi-hole
  ansible.builtin.command:
    cmd: dig +short +time=3 +tries=1 @127.0.0.1 example.com
  register: dig_result
  changed_when: false
  retries: 5
  delay: 3
  until: dig_result.stdout | length > 0
  failed_when: dig_result.stdout | length == 0
YAML

cat > roles/pihole/handlers/main.yml <<'YAML'
---
- name: restart systemd-resolved
  ansible.builtin.systemd:
    name: systemd-resolved
    state: restarted

# down + up — гарантированно пересоздать контейнер
- name: restart pihole
  community.docker.docker_compose_v2:
    project_src: /opt/pihole
    state: absent
  listen: restart pihole

- name: restart pihole (up)
  community.docker.docker_compose_v2:
    project_src: /opt/pihole
    state: present
    recreate: always
  listen: restart pihole
YAML

cat > roles/pihole/templates/docker-compose.yml.j2 <<'YAML'
services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    hostname: pihole
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "80:80/tcp"
    environment:
      TZ: '{{ timezone }}'
      FTLCONF_webserver_api_password: "{{ pihole_password }}"
      FTLCONF_dns_upstreams: '1.1.1.1;8.8.8.8'
      FTLCONF_dns_listeningMode: 'all'
    volumes:
      - './etc-pihole:/etc/pihole'
      - './etc-dnsmasq.d:/etc/dnsmasq.d'
    cap_add:
      - NET_ADMIN
      - SYS_TIME
    dns:
      - 1.1.1.1
      - 8.8.8.8
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "dig", "+short", "+time=2", "@127.0.0.1", "example.com"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 60s
YAML

echo ">>> [1] pihole — OK"

# =============================================================
# 2. РОЛЬ COMMON — NTP, EPEL, auditd service
# =============================================================
cat > roles/common/tasks/main.yml <<'YAML'
---
- name: Set timezone
  community.general.timezone:
    name: "{{ timezone }}"

# ---------------------------------------------------------------------------
# EPEL для RedHat — нужен для fail2ban
# ---------------------------------------------------------------------------
- name: Install EPEL (RedHat)
  ansible.builtin.dnf:
    name: epel-release
    state: present
  when: ansible_os_family == "RedHat"

# ---------------------------------------------------------------------------
# Base packages
# ---------------------------------------------------------------------------
- name: Install base packages (Debian)
  ansible.builtin.apt:
    name:
      - chrony
      - fail2ban
      - auditd
      - unattended-upgrades
      - curl
      - vim
      - htop
      - unzip
      - tar
      - gzip
      - bzip2
    state: present
    update_cache: true
  when: ansible_os_family == "Debian"

- name: Install base packages (RedHat)
  ansible.builtin.dnf:
    name:
      - chrony
      - fail2ban
      - audit
      - dnf-automatic
      - curl
      - vim
      - unzip
      - tar
      - gzip
      - bzip2
    state: present
  when: ansible_os_family == "RedHat"

# ---------------------------------------------------------------------------
# NTP
# ---------------------------------------------------------------------------
- name: Enable chrony (Debian)
  ansible.builtin.service:
    name: chrony
    state: started
    enabled: true
  when: ansible_os_family == "Debian"

- name: Enable chronyd (RedHat)
  ansible.builtin.service:
    name: chronyd
    state: started
    enabled: true
  when: ansible_os_family == "RedHat"

# ---------------------------------------------------------------------------
# auditd — включить и запустить
# ---------------------------------------------------------------------------
- name: Enable auditd
  ansible.builtin.service:
    name: auditd
    state: started
    enabled: true

# ---------------------------------------------------------------------------
# SSH hardening
# ---------------------------------------------------------------------------
- name: Create sshd_config.d directory
  ansible.builtin.file:
    path: /etc/ssh/sshd_config.d
    state: directory
    mode: '0755'

- name: SSH hardening drop-in
  ansible.builtin.template:
    src: 99-hardening.conf.j2
    dest: /etc/ssh/sshd_config.d/99-hardening.conf
    owner: root
    group: root
    mode: '0644'
    validate: '/usr/sbin/sshd -t -f %s'
  notify: restart sshd

- name: Enable fail2ban
  ansible.builtin.service:
    name: fail2ban
    state: started
    enabled: true
YAML

echo ">>> [2] common — OK"

# =============================================================
# 3. PROMTAIL — кросс-дистрибутивный шаблон (Rocky: messages/secure)
# =============================================================
cat > roles/promtail/templates/promtail-config.yml.j2 <<'YAML'
server:
  http_listen_port: 9080

positions:
  filename: /tmp/positions.yaml

clients:
  - url: {{ loki_url }}

scrape_configs:
  - job_name: syslog
    static_configs:
      - targets: [localhost]
        labels:
          job: syslog
          host: {{ inventory_hostname }}
          __path__: |
            {%- if ansible_os_family == "RedHat" -%}
            /var/log/messages
            {%- else -%}
            /var/log/syslog
            {%- endif -%}

  - job_name: auth
    static_configs:
      - targets: [localhost]
        labels:
          job: auth
          host: {{ inventory_hostname }}
          __path__: |
            {%- if ansible_os_family == "RedHat" -%}
            /var/log/secure
            {%- else -%}
            /var/log/auth.log
            {%- endif -%}

  - job_name: nginx
    static_configs:
      - targets: [localhost]
        labels:
          job: nginx
          host: {{ inventory_hostname }}
          __path__: /var/log/nginx/*.log

  - job_name: fail2ban
    static_configs:
      - targets: [localhost]
        labels:
          job: fail2ban
          host: {{ inventory_hostname }}
          __path__: /var/log/fail2ban.log
YAML

echo ">>> [3] promtail — OK"

# =============================================================
# 4. WIREGUARD — интерфейс из факта
# =============================================================
cat > roles/wireguard/templates/wg0.conf.j2 <<'YAML'
[Interface]
Address = 10.10.0.1/24
ListenPort = 51820
PrivateKey = {{ wg_server_private_key }}
PostUp = iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o {{ ansible_default_ipv4.interface }} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s 10.10.0.0/24 -o {{ ansible_default_ipv4.interface }} -j MASQUERADE

[Peer]
PublicKey = {{ wg_client_public_key }}
AllowedIPs = 10.10.0.2/32
YAML

echo ">>> [4] wireguard — OK"

# =============================================================
# 5. MONITORING_STACK — template prometheus, grafana provisioning, loki volume
# =============================================================
mkdir -p roles/monitoring_stack/{files,templates,tasks,handlers}
mkdir -p roles/monitoring_stack/files/grafana-provisioning/{datasources,dashboards}

# 5.1 Prometheus — из шаблона, targets из inventory
cat > roles/monitoring_stack/templates/prometheus.yml.j2 <<'YAML'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

rule_files:
  - /etc/prometheus/alerts.yml

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node'
    static_configs:
      - targets:
{% for h in groups['all'] %}
          - '{{ hostvars[h].ansible_host }}:9100'
{% endfor %}
YAML

# 5.2 Loki config
cat > roles/monitoring_stack/files/loki-config.yml <<'YAML'
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  allow_structured_metadata: true

ruler:
  alertmanager_url: http://alertmanager:9093
YAML

# 5.3 Grafana datasources
cat > roles/monitoring_stack/files/grafana-provisioning/datasources/prometheus.yml <<'YAML'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
YAML

cat > roles/monitoring_stack/files/grafana-provisioning/datasources/loki.yml <<'YAML'
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    editable: false
    jsonData:
      maxLines: 5000
YAML

# 5.4 Grafana dashboards provider
cat > roles/monitoring_stack/files/grafana-provisioning/dashboards/dashboards.yml <<'YAML'
apiVersion: 1
providers:
  - name: default
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
      foldersFromFilesStructure: false
YAML

# 5.5 Минимальные дашборды-заглушки (замени на grafana.com ID 1860 / 13639, если хочешь)
cat > roles/monitoring_stack/files/grafana-provisioning/dashboards/nodes.json <<'JSON'
{
  "title": "Nodes",
  "uid": "nodes-01",
  "schemaVersion": 39,
  "panels": [
    {
      "type": "timeseries",
      "title": "CPU %",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
      "targets": [{
        "expr": "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)",
        "legendFormat": "{{instance}}"
      }]
    },
    {
      "type": "timeseries",
      "title": "RAM used %",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
      "targets": [{
        "expr": "(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100",
        "legendFormat": "{{instance}}"
      }]
    },
    {
      "type": "timeseries",
      "title": "Disk used %",
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 8},
      "targets": [{
        "expr": "(1 - (node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay\"})) * 100",
        "legendFormat": "{{instance}} {{mountpoint}}"
      }]
    }
  ]
}
JSON

cat > roles/monitoring_stack/files/grafana-provisioning/dashboards/logs.json <<'JSON'
{
  "title": "Logs",
  "uid": "logs-01",
  "schemaVersion": 39,
  "panels": [
    {
      "type": "logs",
      "title": "Nginx",
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 0},
      "datasource": {"type": "loki", "uid": "loki"},
      "targets": [{"expr": "{job=\"nginx\"}"}]
    },
    {
      "type": "logs",
      "title": "Syslog",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 8},
      "datasource": {"type": "loki", "uid": "loki"},
      "targets": [{"expr": "{job=\"syslog\"}"}]
    },
    {
      "type": "logs",
      "title": "fail2ban",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8},
      "datasource": {"type": "loki", "uid": "loki"},
      "targets": [{"expr": "{job=\"fail2ban\"}"}]
    }
  ]
}
JSON

# 5.6 docker-compose — grafana provisioning + loki volume
cat > roles/monitoring_stack/templates/docker-compose.yml.j2 <<'YAML'
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - ./alerts.yml:/etc/prometheus/alerts.yml
      - prometheus_data:/prometheus
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "{{ grafana_admin_password }}"
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana-provisioning:/etc/grafana/provisioning:ro
    restart: unless-stopped

  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml
    restart: unless-stopped

  loki:
    image: grafana/loki:latest
    container_name: loki
    ports:
      - "3100:3100"
    command: -config.file=/etc/loki/local-config.yaml
    volumes:
      - loki_data:/loki
      - ./loki-config.yml:/etc/loki/local-config.yaml:ro
    restart: unless-stopped

  promtail:
    image: grafana/promtail:latest
    container_name: promtail
    command: -config.file=/etc/promtail/config.yml
    volumes:
      - /var/log:/var/log:ro
      - ./promtail-config.yml:/etc/promtail/config.yml:ro
    restart: unless-stopped

volumes:
  prometheus_data:
  grafana_data:
  loki_data:
YAML

# 5.7 promtail-config для vm-ctrl (внутри контейнера)
cat > roles/monitoring_stack/files/promtail-config.yml <<'YAML'
server:
  http_listen_port: 9080
positions:
  filename: /tmp/positions.yaml
clients:
  - url: http://loki:3100/loki/api/v1/push
scrape_configs:
  - job_name: syslog
    static_configs:
      - targets: [localhost]
        labels:
          job: syslog
          host: vm-ctrl
          __path__: /var/log/syslog
  - job_name: fail2ban
    static_configs:
      - targets: [localhost]
        labels:
          job: fail2ban
          host: vm-ctrl
          __path__: /var/log/fail2ban.log
YAML

# 5.8 tasks/main.yml — с provisioning, loki-config, promtail-config, verify
cat > roles/monitoring_stack/tasks/main.yml <<'YAML'
---
- name: Create monitoring directory
  ansible.builtin.file:
    path: /opt/monitoring
    state: directory
    mode: '0755'

- name: Copy docker-compose.yml
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: /opt/monitoring/docker-compose.yml
    mode: '0644'
  notify: restart monitoring

- name: Copy prometheus.yml (template — targets из inventory)
  ansible.builtin.template:
    src: prometheus.yml.j2
    dest: /opt/monitoring/prometheus.yml
    mode: '0644'
  notify: restart monitoring

- name: Copy alerts.yml
  ansible.builtin.copy:
    src: alerts.yml
    dest: /opt/monitoring/alerts.yml
    mode: '0644'
  notify: restart monitoring

- name: Copy alertmanager.yml
  ansible.builtin.template:
    src: alertmanager.yml.j2
    dest: /opt/monitoring/alertmanager.yml
    mode: '0644'
  notify: restart monitoring

- name: Copy loki-config.yml
  ansible.builtin.copy:
    src: loki-config.yml
    dest: /opt/monitoring/loki-config.yml
    mode: '0644'
  notify: restart monitoring

- name: Copy promtail-config.yml (для контейнера)
  ansible.builtin.copy:
    src: promtail-config.yml
    dest: /opt/monitoring/promtail-config.yml
    mode: '0644'
  notify: restart monitoring

- name: Copy Grafana provisioning
  ansible.builtin.copy:
    src: grafana-provisioning/
    dest: /opt/monitoring/grafana-provisioning/
    mode: '0644'
  notify: restart monitoring

- name: Start monitoring stack
  community.docker.docker_compose_v2:
    project_src: /opt/monitoring
    state: present

# --- ПРОВЕРКИ ---
- name: Wait for Prometheus
  ansible.builtin.uri:
    url: http://127.0.0.1:9090/-/ready
    status_code: 200
  register: prom
  retries: 30
  delay: 3
  until: prom.status == 200

- name: Wait for Grafana
  ansible.builtin.uri:
    url: http://127.0.0.1:3000/api/health
    status_code: 200
  register: graf
  retries: 30
  delay: 3
  until: graf.status == 200

- name: Wait for Loki
  ansible.builtin.uri:
    url: http://127.0.0.1:3100/ready
    status_code: 200
  register: lok
  retries: 30
  delay: 3
  until: lok.status == 200

- name: Wait for Alertmanager
  ansible.builtin.uri:
    url: http://127.0.0.1:9093/-/ready
    status_code: 200
  register: am
  retries: 30
  delay: 3
  until: am.status == 200
YAML

cat > roles/monitoring_stack/handlers/main.yml <<'YAML'
---
- name: restart monitoring
  community.docker.docker_compose_v2:
    project_src: /opt/monitoring
    state: absent
  listen: restart monitoring

- name: restart monitoring (up)
  community.docker.docker_compose_v2:
    project_src: /opt/monitoring
    state: present
    recreate: always
  listen: restart monitoring
YAML

# Удаляем старый files/prometheus.yml — теперь template
rm -f roles/monitoring_stack/files/prometheus.yml

echo ">>> [5] monitoring_stack — OK"

# =============================================================
# 6. SITE.YML — убираем promtail с control (он теперь в docker)
# =============================================================
python3 - <<'PY'
import re, pathlib
p = pathlib.Path("playbooks/site.yml")
s = p.read_text()
# В блоке "Monitoring stack" убираем роль promtail (она теперь в compose)
s = s.replace(
"""- name: Monitoring stack on control node
  hosts: control
  become: true
  roles:
    - role: docker
      tags: [docker]
    - role: node_exporter
      tags: [node_exporter]
    - role: promtail
      tags: [promtail]
    - role: monitoring_stack
      tags: [monitoring_stack]""",
"""- name: Monitoring stack on control node
  hosts: control
  become: true
  roles:
    - role: docker
      tags: [docker]
    - role: node_exporter
      tags: [node_exporter]
    # promtail на vm-ctrl работает в Docker (внутри monitoring_stack)
    - role: monitoring_stack
      tags: [monitoring_stack]"""
)
p.write_text(s)
print("site.yml patched")
PY

echo ">>> [6] site.yml — OK"

# =============================================================
# 7. CI — hadolint + без || true
# =============================================================
mkdir -p .github/workflows
cat > .github/workflows/ci.yml <<'YAML'
name: Ansible Lint

on:
  push:
    branches: [main]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Install ansible + lint
        run: |
          pip install ansible-core ansible-lint
          ansible-galaxy collection install community.general community.docker ansible.posix

      - name: Run ansible-lint
        run: ansible-lint playbooks/ roles/

      - name: Install shellcheck
        run: sudo apt-get install -y shellcheck

      - name: Run shellcheck
        run: |
          if find . -name "*.sh" | grep -q .; then
            find . -name "*.sh" -exec shellcheck {} +
          else
            echo "No shell scripts — skipping"
          fi

      - name: Hadolint
        uses: hadolint/hadolint-action@v3.1.0
        with:
          dockerfile: "**/Dockerfile*"
          ignore: DL3018,DL3008
          recursive: true
        continue-on-error: true
YAML

echo ">>> [7] CI — OK"

# =============================================================
# ФИНАЛ
# =============================================================
echo ""
echo "=============================================="
echo " ВСЕ ПРАВКИ ПРИМЕНЕНЫ"
echo "=============================================="
echo ""
echo "Дальше:"
echo "  ansible-playbook playbooks/site.yml --check --diff"
echo "  ansible-playbook playbooks/site.yml"
echo "  ansible-playbook playbooks/site.yml   # должен быть changed=0"
echo ""
