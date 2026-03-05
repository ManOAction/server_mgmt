# Server Management (Homelab)

A lightweight, reproducible **server management stack** for running and hardening a public-facing Ubuntu homelab host. It bundles together services for web traffic routing, TLS certificates, dynamic DNS, firewall rules, and intrusion prevention.

---

## Architecture

| Component | Runs In | Purpose |
|-----------|---------|---------|
| **NGINX** | Docker | Reverse proxy, TLS termination, static hosting |
| **Certbot** | Docker | Let's Encrypt certificates via Route 53 DNS-01 |
| **Tasks** | Docker | Scheduled jobs (DDNS, cert renewal, health checks) |
| **Fail2ban** | Host | Log-based intrusion prevention |
| **UFW** | Host | Firewall port allowlisting |
| **SSHD** | Host | Key-only access, hardened config |

Containerized services share an external `edge-proxy` Docker network. Security services (Fail2ban, UFW, SSHD) run directly on the host for deeper system access.

---

## Quick Start

```bash
# 1. Create the external Docker network
docker network create edge-proxy

# 2. Copy and fill in environment variables
cp .env.example .env
# Edit .env with your AWS credentials, Route 53 zone, etc.

# 3. Harden SSH and create deploy user
sudo bash scripts/ssh-hardening.sh
sudo bash scripts/add-user.sh deploy /tmp/deploy_id_rsa.pub

# 4. Start services
docker compose up -d

# 5. Verify the environment
bash tests/check-environment.sh
```

---

## Services

### NGINX

- Image: `nginx:1.27-alpine`
- Ports: **80** (HTTP redirect / ACME), **443** (TLS)
- Config: `nginx/conf.d/`
- Static files: `nginx/html/`
- Logs: `nginx/log/`

Features configured in `nginx/conf.d/00-default-ssl.conf`:
- App proxy (`app.wintermind.io` -> `web:3000`)
- Apex domain static file serving
- Security headers (HSTS, CSP, X-Frame-Options, Referrer-Policy, Permissions-Policy)
- Secret/dotfile blocking (`.env`, `.git`, `*.key`, etc.)
- HTTP method allowlisting (GET/HEAD/POST only)
- Path traversal guards
- WebSocket upgrade support

```bash
docker exec nginx nginx -t        # Test config
docker exec nginx nginx -s reload # Reload config
docker logs nginx                  # View logs
```

---

### Certbot

- Custom image (`certbot/Dockerfile`) with the Route 53 DNS plugin pre-installed.
- Certificates are issued via DNS-01 challenges against AWS Route 53.
- Persistent certs stored in the `certbot-certs` Docker volume, mounted read-only by NGINX.

```bash
# Obtain a cert (one-time or after volume loss)
docker compose run --rm certbot certonly \
  --dns-route53 --non-interactive --agree-tos \
  --email you@example.com \
  -d wintermind.io -d '*.wintermind.io'

# Check cert status
docker compose run --rm certbot certificates

# Test renewal
docker compose run --rm certbot renew --dry-run
```

Automated renewal is handled by the **tasks** scheduler (see below).

---

### Tasks (Scheduled Jobs)

A Python container using **APScheduler** to run background jobs. Built from `tasks/` and has Docker socket access for container orchestration.

**Jobs:**

| Job | File | Schedule |
|-----|------|----------|
| Health check heartbeat | `jobs/hello.py` | Every `HELLO_INTERVAL_MIN` minutes |
| Dynamic DNS (Route 53) | `jobs/ddns_route53.py` | Every `DDNS_INTERVAL_MIN` minutes |
| Dynamic DNS (Cloudflare) | `jobs/ddns_cloudflare.py` | Every `DDNS_INTERVAL_MIN` minutes |
| Certificate renewal | `jobs/certbot_renewal.py` | Every 24 hours |
| Certificate status check | `jobs/certbot_renewal.py` | Every 168 hours (weekly) |

The DDNS jobs fetch your public IP and update DNS records if changed. Certbot renewal triggers `certbot renew` inside a container and reloads NGINX on success.

```bash
docker logs tasks  # View scheduler output
```

---

### Fail2ban

Host-based intrusion prevention. Config: `fail2ban/jail.local`.

**Jails:**

| Jail | Monitors | Threshold | Ban Duration |
|------|----------|-----------|-------------|
| `sshd` | SSH login attempts | 3 failures / 10 min | 24h (escalating) |
| `nginx-botsearch` | NGINX bot scanning | 3 matches / 10 min | 24h (escalating) |
| `nginx-bad-request` | Malformed HTTP requests | 6 matches / 10 min | 24h (escalating) |

All jails use progressive banning (exponential backoff, max 336h).

```bash
# Install config
sudo cp fail2ban/jail.local /etc/fail2ban/jail.local
sudo chown root:root /etc/fail2ban/jail.local
sudo chmod 644 /etc/fail2ban/jail.local
sudo systemctl restart fail2ban

# Common commands
sudo fail2ban-client status            # Jail summary
sudo fail2ban-client status sshd       # SSHD jail details
sudo fail2ban-client banned            # Currently banned IPs
sudo fail2ban-client set sshd unbanip 192.0.2.123  # Unban IP
sudo tail -f /var/log/fail2ban.log     # Tail log
```

---

### UFW (Firewall)

```bash
# Baseline rules
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 80/tcp    # HTTP
sudo ufw allow 443/tcp   # HTTPS
sudo ufw enable

# Management
sudo ufw status verbose
sudo ufw status numbered
sudo ufw logging on
```

---

### SSHD Hardening

`scripts/ssh-hardening.sh` creates an overlay at `/etc/ssh/sshd_config.d/99-hardening.conf`:
- Disables root login and password authentication
- Enforces key-based auth only
- Restricts to modern ciphers (curve25519, chacha20-poly1305, aes256-gcm)
- Sets connection limits and timeouts
- Backs up existing config with timestamp

```bash
sudo bash scripts/ssh-hardening.sh
```

### User Management

`scripts/add-user.sh` creates SSH users with key-based access:

```bash
sudo bash scripts/add-user.sh <username> <public_key_file>
```

Creates the user, disables their password, adds to sudo group, and sets up `~/.ssh/authorized_keys`.

---

## Tests

### Environment Readiness (`check-environment.sh`)

Run before first deployment to verify prerequisites are in place:

- OS & kernel detection (Ubuntu)
- Docker and Docker Compose v2
- `edge-proxy` network existence
- NGINX container running and attached
- `certbot-certs` volume present
- Fail2ban and UFW active with correct rules
- SSHD hardening applied (no root login, key-only auth)
- DNS resolution for `wintermind.io`
- Disk (>=10GB) and RAM (>=2GB) availability
- Ports 80/443 listening

```bash
bash tests/check-environment.sh
```

### Health & Security Audit (`check-health.sh`)

Run periodically (or via cron) to detect misconfigurations, security regressions, and operational issues. Requires `sudo` for full results.

- **Container health** — expected containers running, crash-loop detection
- **NGINX validation** — config syntax check, worker processes alive
- **TLS certificate expiration** — days remaining, warns at 30d, fails at 7d
- **Tasks scheduler** — recent log output confirms scheduler is alive
- **Fail2ban** — service active, all expected jails running, banned IP count
- **UFW audit** — active with deny-incoming default, unexpected port detection
- **Open ports scan** — flags any listening ports beyond 22/80/443
- **SSHD security** — root login, password auth, empty passwords, X11/agent forwarding, modern ciphers, hardening overlay
- **SSH login attempts** — failed auth count from last 24h via journalctl
- **File permissions** — `.env` not world-readable, Docker socket access, world-writable project files
- **Security headers** — curls the live site to verify HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy
- **Log file sizes** — flags NGINX logs over 500MB
- **Docker image freshness** — warns if containers are older than 90 days
- **Unattended upgrades** — verifies automatic security patches are enabled
- **Resources** — disk usage and available RAM

```bash
sudo bash tests/check-health.sh
```

Both scripts generate a pass/warn/fail report and exit 0 (healthy) or 1 (issues found).

---

## Environment Variables

Copy `.env.example` to `.env` and configure:

```
# Schedules
DDNS_INTERVAL_MIN  = 5
HELLO_INTERVAL_MIN = 1

# AWS / Route 53
ACCESS_KEY_ID      = ...
SECRET_ACCESS_KEY  = ...
R53_HOSTED_ZONE_ID = ...
R53_DNS_NAME       = home.example.com
R53_TTL            = 300
R53_IPV6           = false
AWS_REGION         = us-east-1

# Cloudflare (alternative DDNS)
CF_API_TOKEN       = ...
CF_ZONE_ID         = ...
CF_DNS_NAME        = ...
CF_PROXIED         = false
```

---

## Project Structure

```
.
├── certbot/              # Certbot Dockerfile (Route 53 plugin)
├── docker-compose.yml    # Service orchestration
├── fail2ban/
│   └── jail.local        # Fail2ban jail config
├── nginx/
│   ├── conf.d/           # NGINX site configs
│   ├── html/             # Static files
│   └── log/              # Access/error logs
├── scripts/
│   ├── add-user.sh       # Create SSH users
│   └── ssh-hardening.sh  # Harden SSHD config
├── tasks/
│   ├── Dockerfile
│   ├── scheduler.py      # APScheduler entry point
│   ├── config.py         # Environment config
│   └── jobs/             # Scheduled job modules
│       ├── hello.py
│       ├── ddns_route53.py
│       ├── ddns_cloudflare.py
│       └── certbot_renewal.py
└── tests/
    ├── check-environment.sh  # Deployment readiness checks
    └── check-health.sh       # Ongoing health & security audit
```

---

## Notes

- Certificates live in the `certbot-certs` named volume. Do **not** delete it unless you intend to reissue.
- The `edge-proxy` external network allows other Compose projects to share the NGINX reverse proxy.
- Lazydocker is recommended for interactive container monitoring -- install it directly on the host rather than as a container.
- For multi-host or production use, consider adding monitoring (Uptime Kuma, Netdata, Prometheus).
