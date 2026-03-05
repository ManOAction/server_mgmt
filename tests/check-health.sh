#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Server Health & Security Audit
# Run periodically on the target Ubuntu server to detect misconfigurations,
# security regressions, and operational issues.
# Usage:  sudo bash tests/check-health.sh
# ---------------------------------------------------------------------------

set -euo pipefail

PASS=0
FAIL=0
WARN=0

pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
warn() { WARN=$((WARN + 1)); echo "  [WARN] $1"; }

section() { echo ""; echo "== $1 =="; }

DOMAIN="wintermind.io"

# ---- 1. Container Health --------------------------------------------------
section "Container Health"

EXPECTED_CONTAINERS="nginx tasks"

for ctr in $EXPECTED_CONTAINERS; do
    if docker ps --format '{{.Names}}' | grep -qx "$ctr"; then
        # Check if container is restart-looping
        restart_count=$(docker inspect --format '{{.RestartCount}}' "$ctr" 2>/dev/null || echo "0")
        started_at=$(docker inspect --format '{{.State.StartedAt}}' "$ctr" 2>/dev/null || echo "")
        if [ "$restart_count" -gt 5 ]; then
            warn "$ctr is running but has restarted $restart_count times (possible crash loop)"
        else
            pass "$ctr is running (restarts: $restart_count)"
        fi
    else
        fail "$ctr container is not running"
    fi
done

# Check for containers in unhealthy or restarting state
unhealthy=$(docker ps --filter "status=restarting" --format '{{.Names}}' 2>/dev/null || true)
if [ -n "$unhealthy" ]; then
    fail "Containers in restarting state: $unhealthy"
else
    pass "No containers stuck in restarting state"
fi

# ---- 2. NGINX Validation --------------------------------------------------
section "NGINX"

if docker ps --format '{{.Names}}' | grep -qx nginx; then
    # Config syntax
    if docker exec nginx nginx -t 2>&1 | grep -q "syntax is ok"; then
        pass "NGINX config syntax is valid"
    else
        fail "NGINX config syntax check failed"
    fi

    # Check worker process is responding
    if docker exec nginx pgrep -x "nginx" >/dev/null 2>&1; then
        pass "NGINX worker processes are running"
    else
        warn "NGINX worker processes may not be running"
    fi
else
    fail "NGINX container not running — skipping NGINX checks"
fi

# ---- 3. TLS Certificate Expiration ----------------------------------------
section "TLS Certificates"

if docker ps --format '{{.Names}}' | grep -qx nginx; then
    cert_path="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    expiry=$(docker exec nginx openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2)

    if [ -n "$expiry" ]; then
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo "")
        now_epoch=$(date +%s)

        if [ -n "$expiry_epoch" ]; then
            days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            if [ "$days_left" -le 0 ]; then
                fail "TLS certificate has EXPIRED ($expiry)"
            elif [ "$days_left" -le 7 ]; then
                fail "TLS certificate expires in $days_left days ($expiry)"
            elif [ "$days_left" -le 30 ]; then
                warn "TLS certificate expires in $days_left days ($expiry)"
            else
                pass "TLS certificate valid for $days_left more days (expires $expiry)"
            fi
        else
            warn "Could not parse certificate expiry date"
        fi
    else
        fail "Could not read TLS certificate at $cert_path"
    fi
else
    fail "NGINX not running — cannot check TLS certificates"
fi

# ---- 4. Tasks Scheduler ---------------------------------------------------
section "Tasks Scheduler"

if docker ps --format '{{.Names}}' | grep -qx tasks; then
    # Check if scheduler has produced recent log output (within last hour)
    last_log=$(docker logs --since 1h tasks 2>&1 | tail -1)
    if [ -n "$last_log" ]; then
        pass "Tasks scheduler has produced output in the last hour"
    else
        warn "Tasks scheduler has no log output in the last hour"
    fi
else
    fail "Tasks container is not running"
fi

# ---- 5. Fail2ban Health ---------------------------------------------------
section "Fail2ban"

if systemctl is-active --quiet fail2ban 2>/dev/null; then
    pass "Fail2ban service is active"

    # Check expected jails are running
    EXPECTED_JAILS="sshd nginx-botsearch nginx-bad-request"
    active_jails=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*://;s/,/ /g' | xargs)

    for jail in $EXPECTED_JAILS; do
        if echo "$active_jails" | grep -qw "$jail"; then
            pass "Jail '$jail' is active"
        else
            fail "Jail '$jail' is not active"
        fi
    done

    # Report banned IP count
    total_banned=$(fail2ban-client banned 2>/dev/null | grep -o '"[^"]*"' | wc -l || echo "0")
    if [ "$total_banned" -gt 0 ]; then
        pass "Currently banning $total_banned IP(s)"
    else
        pass "No IPs currently banned"
    fi
else
    fail "Fail2ban service is not active"
fi

# ---- 6. UFW Firewall Audit ------------------------------------------------
section "UFW Firewall"

if command -v ufw &>/dev/null; then
    ufw_status=$(ufw status verbose 2>/dev/null || true)

    if echo "$ufw_status" | grep -qi "Status: active"; then
        pass "UFW is active"
    else
        fail "UFW is not active"
    fi

    # Check default incoming policy
    if echo "$ufw_status" | grep -qi "Default:.*deny (incoming)"; then
        pass "Default incoming policy is deny"
    else
        fail "Default incoming policy is not deny — all ports may be exposed"
    fi

    # Check for unexpected allowed ports
    EXPECTED_PORTS="22 80 443"
    allowed_ports=$(echo "$ufw_status" | grep "ALLOW" | grep -oP '^\d+' | sort -un)
    unexpected=""
    for port in $allowed_ports; do
        if ! echo "$EXPECTED_PORTS" | grep -qw "$port"; then
            unexpected="$unexpected $port"
        fi
    done

    if [ -n "$unexpected" ]; then
        warn "Unexpected ports allowed through UFW:$unexpected"
    else
        pass "Only expected ports (22, 80, 443) are allowed"
    fi
else
    fail "UFW is not installed"
fi

# ---- 7. Open Ports Scan ---------------------------------------------------
section "Open Ports"

if command -v ss &>/dev/null; then
    listening=$(ss -tlnp 2>/dev/null | grep LISTEN | awk '{print $4}' | grep -oP '\d+$' | sort -un)
    EXPECTED_LISTENING="22 80 443"
    unexpected=""

    for port in $listening; do
        if ! echo "$EXPECTED_LISTENING" | grep -qw "$port"; then
            unexpected="$unexpected $port"
        fi
    done

    if [ -n "$unexpected" ]; then
        warn "Unexpected ports listening:$unexpected (verify these are intentional)"
    else
        pass "Only expected ports are listening (22, 80, 443)"
    fi
else
    warn "ss not available — cannot audit listening ports"
fi

# ---- 8. SSHD Security Audit -----------------------------------------------
section "SSHD Security"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-hardening.conf"

if [ -f "$SSHD_CONFIG" ]; then
    effective_config=$(cat "$SSHD_CONFIG" /etc/ssh/sshd_config.d/*.conf 2>/dev/null || cat "$SSHD_CONFIG")

    # Root login
    if echo "$effective_config" | grep -qi "^PermitRootLogin\s*no"; then
        pass "Root login is disabled"
    else
        fail "Root login may be enabled"
    fi

    # Password auth
    if echo "$effective_config" | grep -qi "^PasswordAuthentication\s*no"; then
        pass "Password authentication is disabled"
    else
        fail "Password authentication may be enabled"
    fi

    # Empty passwords
    if echo "$effective_config" | grep -qi "^PermitEmptyPasswords\s*no"; then
        pass "Empty passwords are denied"
    else
        warn "PermitEmptyPasswords not explicitly set to no"
    fi

    # X11 forwarding
    if echo "$effective_config" | grep -qi "^X11Forwarding\s*no"; then
        pass "X11 forwarding is disabled"
    else
        warn "X11 forwarding may be enabled"
    fi

    # Agent forwarding
    if echo "$effective_config" | grep -qi "^AllowAgentForwarding\s*no"; then
        pass "Agent forwarding is disabled"
    else
        warn "Agent forwarding may be enabled"
    fi

    # Hardening overlay present
    if [ -f "$SSHD_DROPIN" ]; then
        pass "SSH hardening overlay is installed ($SSHD_DROPIN)"
    else
        warn "SSH hardening overlay not found — run scripts/ssh-hardening.sh"
    fi

    # Modern ciphers
    if echo "$effective_config" | grep -qi "^Ciphers.*chacha20-poly1305"; then
        pass "Modern ciphers configured (chacha20-poly1305)"
    else
        warn "Modern ciphers may not be configured"
    fi
else
    fail "SSHD config not found at $SSHD_CONFIG"
fi

# ---- 9. Recent Failed SSH Logins ------------------------------------------
section "SSH Login Attempts"

if command -v journalctl &>/dev/null; then
    failed_24h=$(journalctl -u ssh -u sshd --since "24 hours ago" 2>/dev/null \
        | grep -ci "Failed\|Invalid user\|authentication failure" || echo "0")

    if [ "$failed_24h" -gt 100 ]; then
        warn "$failed_24h failed SSH attempts in the last 24h (possible brute-force)"
    elif [ "$failed_24h" -gt 0 ]; then
        pass "$failed_24h failed SSH attempt(s) in the last 24h"
    else
        pass "No failed SSH attempts in the last 24h"
    fi
else
    warn "journalctl not available — cannot check SSH login history"
fi

# ---- 10. File Permissions --------------------------------------------------
section "File Permissions"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# .env should not be world-readable
if [ -f "$SCRIPT_DIR/.env" ]; then
    env_perms=$(stat -c "%a" "$SCRIPT_DIR/.env" 2>/dev/null || echo "unknown")
    if [ "$env_perms" = "600" ] || [ "$env_perms" = "640" ]; then
        pass ".env file permissions are restrictive ($env_perms)"
    else
        warn ".env file is too permissive ($env_perms) — recommend chmod 600"
    fi
else
    pass "No .env file found (using example or injected vars)"
fi

# Docker socket permissions
if [ -S /var/run/docker.sock ]; then
    sock_group=$(stat -c "%G" /var/run/docker.sock 2>/dev/null || echo "unknown")
    sock_perms=$(stat -c "%a" /var/run/docker.sock 2>/dev/null || echo "unknown")
    if [ "$sock_perms" = "660" ] || [ "$sock_perms" = "770" ]; then
        pass "Docker socket permissions are appropriate ($sock_perms, group: $sock_group)"
    else
        warn "Docker socket permissions ($sock_perms) — verify only docker group has access"
    fi
else
    warn "Docker socket not found at /var/run/docker.sock"
fi

# World-writable files in project
world_writable=$(find "$SCRIPT_DIR" -maxdepth 3 -type f -perm -o+w \
    ! -path "*/.git/*" ! -path "*/node_modules/*" 2>/dev/null | head -5)
if [ -n "$world_writable" ]; then
    warn "World-writable files found in project:"
    echo "$world_writable" | while read -r f; do echo "        $f"; done
else
    pass "No world-writable files in project directory"
fi

# ---- 11. NGINX Security Headers -------------------------------------------
section "NGINX Security Headers (via curl)"

if command -v curl &>/dev/null; then
    # Only test if port 443 is actually listening
    if ss -tlnp 2>/dev/null | grep -q ':443 '; then
        headers=$(curl -sI --connect-timeout 5 --max-time 10 \
            "https://$DOMAIN" 2>/dev/null || true)

        if [ -n "$headers" ]; then
            check_header() {
                local header="$1"
                local label="$2"
                if echo "$headers" | grep -qi "^$header"; then
                    pass "$label header present"
                else
                    warn "$label header missing"
                fi
            }

            check_header "Strict-Transport-Security" "HSTS"
            check_header "X-Frame-Options" "X-Frame-Options"
            check_header "X-Content-Type-Options" "X-Content-Type-Options"
            check_header "Referrer-Policy" "Referrer-Policy"
        else
            warn "Could not reach https://$DOMAIN — skipping header checks"
        fi
    else
        warn "Port 443 not listening — skipping header checks"
    fi
else
    warn "curl not available — cannot test security headers"
fi

# ---- 12. Log File Sizes ---------------------------------------------------
section "Log Files"

LOG_DIR="$SCRIPT_DIR/nginx/log"
MAX_LOG_MB=500

if [ -d "$LOG_DIR" ]; then
    oversized=""
    while IFS= read -r logfile; do
        size_mb=$(du -m "$logfile" 2>/dev/null | awk '{print $1}')
        if [ -n "$size_mb" ] && [ "$size_mb" -gt "$MAX_LOG_MB" ]; then
            oversized="$oversized  $logfile (${size_mb}MB)\n"
        fi
    done < <(find "$LOG_DIR" -type f -name "*.log" 2>/dev/null)

    if [ -n "$oversized" ]; then
        warn "Large log files detected (>${MAX_LOG_MB}MB):"
        echo -e "$oversized"
    else
        pass "No oversized log files in nginx/log/"
    fi
else
    warn "NGINX log directory not found at $LOG_DIR"
fi

# ---- 13. Docker Image Freshness -------------------------------------------
section "Docker Images"

for ctr in nginx tasks; do
    if docker ps --format '{{.Names}}' | grep -qx "$ctr"; then
        image_id=$(docker inspect --format '{{.Image}}' "$ctr" 2>/dev/null)
        created=$(docker inspect --format '{{.Created}}' "$ctr" 2>/dev/null | cut -dT -f1)
        if [ -n "$created" ]; then
            created_epoch=$(date -d "$created" +%s 2>/dev/null || echo "")
            now_epoch=$(date +%s)
            if [ -n "$created_epoch" ]; then
                days_old=$(( (now_epoch - created_epoch) / 86400 ))
                if [ "$days_old" -gt 90 ]; then
                    warn "$ctr container created $days_old days ago — consider rebuilding"
                else
                    pass "$ctr container is $days_old days old"
                fi
            fi
        fi
    fi
done

# ---- 14. Unattended Upgrades ----------------------------------------------
section "System Updates"

if dpkg -l unattended-upgrades &>/dev/null 2>&1; then
    if systemctl is-active --quiet unattended-upgrades 2>/dev/null; then
        pass "Unattended security upgrades are active"
    else
        warn "unattended-upgrades is installed but service is not active"
    fi
else
    warn "unattended-upgrades is not installed — security patches won't auto-apply"
fi

# ---- 15. Disk & Memory (quick) --------------------------------------------
section "Resources"

disk_pct=$(df / --output=pcent 2>/dev/null | tail -1 | tr -d ' %')
if [ -n "$disk_pct" ] && [ "$disk_pct" -gt 90 ]; then
    fail "Root filesystem is ${disk_pct}% full"
elif [ -n "$disk_pct" ] && [ "$disk_pct" -gt 80 ]; then
    warn "Root filesystem is ${disk_pct}% full"
elif [ -n "$disk_pct" ]; then
    pass "Root filesystem is ${disk_pct}% full"
fi

mem_avail=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}')
if [ -n "$mem_avail" ] && [ "$mem_avail" -lt 256 ]; then
    fail "Only ${mem_avail}MB RAM available"
elif [ -n "$mem_avail" ] && [ "$mem_avail" -lt 512 ]; then
    warn "${mem_avail}MB RAM available"
elif [ -n "$mem_avail" ]; then
    pass "${mem_avail}MB RAM available"
fi

# ---- Summary ---------------------------------------------------------------
echo ""
echo "==========================================="
echo "  Results:  $PASS passed  /  $WARN warnings  /  $FAIL failed"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
    echo "  Issues detected — review failures above."
    exit 1
else
    echo "  Server health looks good."
    exit 0
fi
