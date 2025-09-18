# Server Management (Homelab)

This repository contains a lightweight **server management stack** for running and protecting a public-facing Ubuntu host. It bundles together common services for managing web traffic, TLS certificates, firewall rules, and intrusion prevention.

The goal is to provide a reproducible way to manage:

- **NGINX** – reverse proxy, TLS termination, and static file hosting
- **Certbot** – automatic TLS certificate management via Let’s Encrypt (DNS-01 with Route 53)
- **Fail2ban** – log-based intrusion prevention and brute-force banning
- **UFW** – firewall rules for port access (to be scripted into this repo)
- **SSHD config** – secure access hardening (to be scripted into this repo)

---

## 🛠️ Services

### NGINX
- Runs as `nginx:1.27-alpine`.
- Handles:
  - Port 80 → HTTP redirects / ACME challenges
  - Port 443 → TLS traffic for apps & static sites
  - Port 8000 → exposed for app debugging if needed
- Config lives in `nginx/conf.d/`.
- Logs are written to `nginx/log/`.

**Check status:**
```bash
docker logs nginx
docker exec nginx nginx -t
```

**Reload after config change:**
```bash
docker exec nginx nginx -s reload
```

---

### Certbot
- Custom image (`./certbot/Dockerfile`) with the **Route 53 plugin** pre-installed.
- Certificates are requested using DNS-01 challenges in AWS Route 53.
- Persistent certs are stored in the `certbot-certs` volume → mounted by NGINX at `/etc/letsencrypt`.

**Obtain a cert (one-time or after volume loss):**
```bash
docker compose run --rm certbot certonly   --dns-route53   --non-interactive   --agree-tos   --email you@example.com   -d wintermind.io -d '*.wintermind.io'
```

**Renewal:**
- Certbot keeps track of certs in `/etc/letsencrypt`.
- Renewal can be scripted in `tasks/jobs/certbot_renewal.py` or run manually:
  ```bash
  docker compose run --rm certbot renew --quiet
  docker exec nginx nginx -s reload
  ```

---

### Fail2ban
- Config in `fail2ban/jail.local`.
- Monitors logs (e.g. SSH, NGINX) and bans IPs that trigger suspicious patterns.
- Runs on the host, not containerized.

**Common commands:**
```bash
# Show jail summary
sudo fail2ban-client status

# Show details for sshd jail
sudo fail2ban-client status sshd

# Check currently banned IPs
sudo fail2ban-client banned

# Unban an IP
sudo fail2ban-client set sshd unbanip 192.0.2.123

# Tail Fail2ban log for recent activity
sudo tail -f /var/log/fail2ban.log
```

---

### UFW (Uncomplicated Firewall)
- Firewall rules for managing network access.
- Suggested baseline rules:
```bash
sudo ufw allow 22/tcp      # SSH
sudo ufw allow 80/tcp      # HTTP
sudo ufw allow 443/tcp     # HTTPS
sudo ufw enable
```

**Common commands:**
```bash
# Show current rules and status
sudo ufw status verbose

# Deny all incoming traffic by default
sudo ufw default deny incoming

# Allow all outgoing traffic by default
sudo ufw default allow outgoing

# Delete a rule (example: rule number 3 from ufw status numbered)
sudo ufw delete 3

# Log dropped packets
sudo ufw logging on
```

---

### SSHD Config
- Planned: manage `/etc/ssh/sshd_config` for hardened defaults:
  - Disable root login
  - Disable password login (keys only)
  - Restrict ciphers and MACs

---

### Tasks
- Runs custom management jobs (Python):
  - `jobs/certbot_renewal.py` – certificate rotation
  - `jobs/ddns_route53.py` and `jobs/ddns_cloudflare.py` – update DNS dynamically
  - Other cron-like or scheduled jobs
- Built from `./tasks` and runs with access to the Docker socket for orchestration.

---

### Lazydocker
- Interactive TUI for monitoring containers.
- Run on-demand:
```bash
docker compose run --rm -it lazydocker
```

---

## 🔍 Management Checklist

- **Nginx config check:**
  `docker exec nginx nginx -t`

- **Reload Nginx:**
  `docker exec nginx nginx -s reload`

- **Check cert expiration:**
  `docker compose run --rm certbot certificates`

- **Test renewal manually:**
  `docker compose run --rm certbot renew --dry-run`

- **Firewall status:**
  `sudo ufw status verbose`

- **Fail2ban status:**
  `sudo fail2ban-client status`

- **Inspect running containers:**
  `docker ps`

- **Logs (per service):**
  `docker logs nginx`
  `docker logs tasks`

---

## 📌 Notes

- Certificates and keys are stored in the `certbot-certs` named volume. Do **not** delete this unless you intend to reissue.
- All security-sensitive processes (UFW, Fail2ban, SSHD) should run on the host system; this repo focuses on NGINX + Certbot + job orchestration.
- For multi-host or production usage, integrate monitoring (e.g., Uptime Kuma, Netdata, or Prometheus).

