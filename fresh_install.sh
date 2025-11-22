#!/usr/bin/env bash

set -euo pipefail

log() {
  echo -e "\n[+] $1"
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Lance ce script en root" >&2
    exit 1
  fi
}

backup_file() {
  local file="$1"
  if [ -f "$file" ]; then
    local ts
    ts=$(date +%Y%m%d%H%M%S)
    cp -a "$file" "${file}.bak-${ts}"
    log "Sauvegarde de $file -> ${file}.bak-${ts}"
  fi
}

set_sshd_option() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"
  if grep -qE "^[#[:space:]]*${key}([[:space:]]|$)" "$file"; then
    sed -i -E "s/^[#[:space:]]*${key}([[:space:]]|$).*/${key} ${value}/" "$file"
  else
    echo "${key} ${value}" >>"$file"
  fi
}

require_root
export DEBIAN_FRONTEND=noninteractive

log "Sauvegarde des fichiers avant modification"
backup_file /etc/ssh/sshd_config
backup_file /etc/fail2ban/jail.local
backup_file /etc/apt/apt.conf.d/50unattended-upgrades

log "Mise a jour du systeme"
apt update
apt full-upgrade -y
apt autoremove -y

log "Langue et fuseau horaire"
apt install -y language-pack-fr language-pack-gnome-fr-base
localectl set-locale LANG=fr_FR.UTF-8

log "Configuration SSH (port 2222, root par cle uniquement)"
apt install -y openssh-server
set_sshd_option Port 2222
set_sshd_option PermitRootLogin prohibit-password
set_sshd_option PasswordAuthentication yes
set_sshd_option PubkeyAuthentication yes
systemctl reload ssh || systemctl restart ssh

log "Pare-feu UFW"
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 2222/tcp comment 'SSH'
ufw logging on
ufw --force enable

log "Fail2Ban pour SSH"
apt install -y fail2ban
cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 3
banaction = ufw

[sshd]
enabled = true
port = 2222
filter = sshd
logpath = /var/log/auth.log
EOF
systemctl enable fail2ban
systemctl restart fail2ban

log "Mises a jour automatiques"
apt install -y unattended-upgrades
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

log "Installation de Docker (depots officiels)"
apt remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true
apt install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu

log "Configuration Docker (rotation des logs)"
install -m 0755 -d /etc/docker
cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
systemctl restart docker

log "Preparation de l'acces root pour Coolify (cle uniquement)"
install -m 700 -d /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

echo -e "\nScript termine."
echo "Ajoute la cle publique de Coolify dans /root/.ssh/authorized_keys."
echo "Change le mot de passe de l'utilisateur ubuntu avec: passwd ubuntu"
