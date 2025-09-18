# 🏠 Homelab Server Setup

This document tracks the setup and evolution of the ProphetsOfDoom homelab server.
The goal is to turn a spare laptop into a self-hosted playground for web apps, development stacks, and server administration practice.

---

## ✅ Completed Setup (Phase 0 → Baseline)

### Hardware

- Repurposed laptop with broken keyboard
- Installed **Ubuntu Server LTS** from bootable USB (created with Rufus)

### Access

- SSH access enabled
- Created **user account** (`jadmin`)
- Verified remote login from workstation
- ssh -i "G:/My Drive/Connections and Keys/jadmin_to_prophets" jadmin@192.168.159.8

### Security

- **SSH keys** generated (`ed25519` primary)
- Configured `~/.ssh/config` for VS Code Remote-SSH
- Disabled password authentication in `sshd_config`
- Configured **UFW firewall**:
  - Deny all incoming by default
  - Allow outgoing
  - Open ports: `22` (SSH), `80` (HTTP), `443` (HTTPS)
  - Check with this -- sudo ufw status
  - Allow w/this -- sudo ufw allow 8080
  - Take effect w/this -- sudo ufw reload

- Installed and configured **Fail2Ban** for SSH brute-force protection

# 📦 Install Fail2Ban

sudo apt update
sudo apt install fail2ban -y

# 🔌 Enable and start Fail2Ban service

sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# 🛠️ Create local jail config (copy from default)

sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

# ✏️ Edit config (enable sshd jail, adjust retries/bantime)

sudo vim /etc/fail2ban/jail.local

# Example sshd section (inside jail.local):

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600

# ♻️ Restart Fail2Ban after changes

sudo systemctl restart fail2ban

# 📋 Check global Fail2Ban status

sudo fail2ban-client status

# 📋 Check jail-specific status (e.g., sshd)

sudo fail2ban-client status sshd

# 🚨 Unban an IP if needed

sudo fail2ban-client set sshd unbanip <IP_ADDRESS>

# 📖 View Fail2Ban logs

sudo less /var/log/fail2ban.log

---

## 📌 Planned Phases

### Phase 1: Core Server Configuration

- [x] Decide on static IP strategy
  - DHCP reservation in router (preferred)
  - or Netplan config on Ubuntu
- [x] Enable **unattended-upgrades** for automatic security patches
- [ ] Set up **system monitoring tools** (`htop`, `glances`)

### Phase 2: Docker & Management

- [x] Install Docker and Docker Compose
- [ ] Add user `jadmin` to Docker group
- [ ] Deploy **LazyDocker** (decided against portainer for now)
- [ ] Deploy **NGINX Proxy Manager** for reverse proxy + TLS

### Phase 3: First Self-Hosted Apps

- [ ] Spin up a "fun app" (Jellyfin, Nextcloud, or similar)
- [ ] Deploy one of our own projects (FastAPI/Django app)
- [ ] Configure HTTPS via NGINX Proxy Manager (Let’s Encrypt)
- [ ] Implement **Dynamic DNS** (Using Cloudflare w/Domain)
    - docker exec -it tasks bash -lc 'python -c "from jobs import ddns_route53; ddns_route53.run()"'


### Phase 4: Networking & Remote Access

- [ ] Expose one app to the public internet securely
- [ ] Explore VPN-based remote access (Tailscale/ZeroTier)

### Phase 5: Operations & Reliability

- [ ] Backups (Restic/Borg, rsync scripts, or snapshots)
- [ ] Automated updates (Renovate, Watchtower)
- [ ] Monitoring & dashboards (Grafana + Prometheus)
- [ ] Document recovery procedures (RUNBOOK)

### Phase 6: Advanced Experiments

- [ ] Virtualization layer (Proxmox or K3s for Kubernetes)
- [ ] CI/CD pipeline for self-hosted projects
- [ ] Additional self-hosted services (wiki, Git server, etc.)

---

## 📂 References

- Ubuntu Server Docs: <https://ubuntu.com/server/docs>
- Fail2Ban: <https://www.fail2ban.org/>
- UFW Firewall: <https://help.ubuntu.com/community/UFW>
- Docker: <https://docs.docker.com/get-docker/>
- NGINX Proxy Manager: <https://nginxproxymanager.com/>
- Portainer: <https://www.portainer.io/>

---

## 📝 Notes

- All secrets (SSH keys, `.env` files) are kept **outside version control**
- Configurations and compose files live in the `stacks/` directory of the repo
- Future additions (e.g., monitoring, backup scripts) will be documented here
