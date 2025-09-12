import logging, requests
from tasks.config import settings

log = logging.getLogger("tasks.ddns")

def _headers():
    return {"Authorization": f"Bearer {settings.CF_API_TOKEN}",
            "Content-Type": "application/json"}

def _get_public_ip() -> str:
    return requests.get("https://checkip.amazonaws.com/", timeout=10).text.strip()

def _get_record_id() -> str:
    url = f"https://api.cloudflare.com/client/v4/zones/{settings.CF_ZONE_ID}/dns_records"
    r = requests.get(url, headers=_headers(), params={"name": settings.CF_DNS_NAME}, timeout=15).json()
    if not r.get("success") or not r.get("result"):
        raise RuntimeError(f"DNS record lookup failed for {settings.CF_DNS_NAME}: {r}")
    return r["result"][0]["id"]

def run():
    if not (settings.CF_API_TOKEN and settings.CF_ZONE_ID and settings.CF_DNS_NAME):
        log.warning("DDNS env not fully set; skipping update.")
        return
    ip = _get_public_ip()
    rid = _get_record_id()
    url = f"https://api.cloudflare.com/client/v4/zones/{settings.CF_ZONE_ID}/dns_records/{rid}"
    payload = {"type": "A", "name": settings.CF_DNS_NAME, "content": ip, "ttl": 300,
               "proxied": settings.CF_PROXIED}
    r = requests.put(url, headers=_headers(), json=payload, timeout=15).json()
    if not r.get("success"):
        raise RuntimeError(f"Cloudflare update error: {r}")
    log.info(f"DDNS updated: {settings.CF_DNS_NAME} -> {ip} (proxied={settings.CF_PROXIED})")
