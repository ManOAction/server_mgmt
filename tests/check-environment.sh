#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Environment Readiness Checks
# Run on the target Ubuntu server before deploying OpenClaw.
# Usage:  bash scripts/check-environment.sh
# ---------------------------------------------------------------------------

set -euo pipefail

PASS=0
FAIL=0
WARN=0

pass() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }
warn() { WARN=$((WARN + 1)); echo "  [WARN] $1"; }

section() { echo ""; echo "== $1 =="; }

# ---- 1. OS & Kernel ---------------------------------------------------
section "OS & Kernel"

if grep -qi ubuntu /etc/os-release 2>/dev/null; then
    ver=$(grep VERSION_ID /etc/os-release | tr -d '"' | cut -d= -f2)
    pass "Ubuntu detected (version $ver)"
else
    fail "Expected Ubuntu — found $(uname -s)"
fi

# ---- 2. Docker ---------------------------------------------------------
section "Docker"

if command -v docker &>/dev/null; then
    pass "Docker is installed ($(docker --version | head -1))"
else
    fail "Docker is not installed"
fi

if docker info &>/dev/null; then
    pass "Docker daemon is running"
else
    fail "Docker daemon is not running or current user lacks access"
fi

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    pass "Docker Compose v2 is available ($(docker compose version --short 2>/dev/null))"
else
    fail "Docker Compose v2 (docker compose) not found"
fi

# ---- 3. Docker network -------------------------------------------------
section "Docker Networking"

if docker network inspect edge-proxy &>/dev/null; then
    pass "edge-proxy network exists"
else
    fail "edge-proxy network does not exist (create with: docker network create edge-proxy)"
fi

# ---- 4. NGINX container ------------------------------------------------
section "NGINX"

if docker ps --format '{{.Names}}' | grep -qx nginx; then
    pass "NGINX container is running"
else
    fail "NGINX container is not running"
fi

if docker ps --filter name=nginx --format '{{.Networks}}' | grep -q edge-proxy; then
    pass "NGINX is attached to edge-proxy network"
else
    warn "NGINX does not appear to be on the edge-proxy network"
fi

# ---- 5. TLS / Certbot --------------------------------------------------
section "TLS Certificates"

# Check certbot-certs volume exists
if docker volume inspect certbot-certs &>/dev/null 2>&1 || \
   docker volume ls --format '{{.Name}}' | grep -q certbot-certs; then
    pass "certbot-certs volume exists"
else
    fail "certbot-certs volume not found"
fi

# ---- 6. Fail2ban -------------------------------------------------------
section "Fail2ban"

if systemctl is-active --quiet fail2ban 2>/dev/null; then
    pass "Fail2ban service is active"
elif command -v fail2ban-client &>/dev/null; then
    warn "Fail2ban is installed but service is not active"
else
    fail "Fail2ban is not installed"
fi

# ---- 7. UFW Firewall ---------------------------------------------------
section "UFW Firewall"

if command -v ufw &>/dev/null; then
    if ufw status | grep -qi "active"; then
        pass "UFW is active"
        # Check essential ports
        if ufw status | grep -q "80"; then
            pass "UFW allows port 80 (HTTP)"
        else
            warn "UFW does not appear to allow port 80"
        fi
        if ufw status | grep -q "443"; then
            pass "UFW allows port 443 (HTTPS)"
        else
            warn "UFW does not appear to allow port 443"
        fi
        if ufw status | grep -q "22"; then
            pass "UFW allows port 22 (SSH)"
        else
            warn "UFW does not appear to allow port 22"
        fi
    else
        warn "UFW is installed but not active"
    fi
else
    fail "UFW is not installed"
fi

# ---- 8. SSHD Hardening -------------------------------------------------
section "SSHD Configuration"

SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    # Combine main config and included drop-in files
    effective_config=$(cat "$SSHD_CONFIG" /etc/ssh/sshd_config.d/*.conf 2>/dev/null || cat "$SSHD_CONFIG")

    if echo "$effective_config" | grep -qi "^PermitRootLogin\s*no"; then
        pass "Root login is disabled"
    else
        warn "Root login may not be disabled (check PermitRootLogin)"
    fi

    if echo "$effective_config" | grep -qi "^PasswordAuthentication\s*no"; then
        pass "Password authentication is disabled (key-only)"
    else
        warn "Password authentication may still be enabled"
    fi
else
    fail "SSHD config not found at $SSHD_CONFIG"
fi

# ---- 9. DNS Resolution -------------------------------------------------
section "DNS"

if command -v dig &>/dev/null; then
    if dig +short wintermind.io | grep -qE '[0-9]'; then
        pass "wintermind.io resolves via DNS"
    else
        warn "wintermind.io does not resolve — DNS may not be configured yet"
    fi
elif command -v nslookup &>/dev/null; then
    if nslookup wintermind.io &>/dev/null; then
        pass "wintermind.io resolves via DNS"
    else
        warn "wintermind.io does not resolve — DNS may not be configured yet"
    fi
else
    warn "Neither dig nor nslookup available — cannot test DNS"
fi

# ---- 10. Disk & Memory -------------------------------------------------
section "Resources"

disk_avail=$(df / --output=avail -BG 2>/dev/null | tail -1 | tr -d ' G')
if [ -n "$disk_avail" ] && [ "$disk_avail" -ge 10 ]; then
    pass "Root filesystem has ${disk_avail}G available"
elif [ -n "$disk_avail" ]; then
    warn "Root filesystem only has ${disk_avail}G available (recommend >= 10G)"
else
    warn "Could not determine available disk space"
fi

mem_total=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1024/1024)}')
if [ -n "$mem_total" ] && [ "$mem_total" -ge 2 ]; then
    pass "System has ${mem_total}G RAM"
elif [ -n "$mem_total" ]; then
    warn "System only has ${mem_total}G RAM (recommend >= 2G)"
else
    warn "Could not determine system memory"
fi

# ---- 11. Ports listening ------------------------------------------------
section "Port Availability"

if ss -tlnp 2>/dev/null | grep -q ':80 '; then
    pass "Something is listening on port 80"
else
    warn "Nothing is listening on port 80"
fi

if ss -tlnp 2>/dev/null | grep -q ':443 '; then
    pass "Something is listening on port 443"
else
    warn "Nothing is listening on port 443"
fi

# ---- Summary -----------------------------------------------------------
echo ""
echo "==========================================="
echo "  Results:  $PASS passed  /  $WARN warnings  /  $FAIL failed"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
    echo "  Environment is NOT ready — fix the failures above."
    exit 1
else
    echo "  Environment looks ready for OpenClaw deployment."
    exit 0
fi
