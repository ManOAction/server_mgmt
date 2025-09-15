# tasks/jobs/ddns_route53.py
import os
import logging
import time
from typing import Optional

import boto3
import botocore
import requests

log = logging.getLogger("tasks.ddns")

def _env(name: str, default: Optional[str] = None) -> Optional[str]:
    v = os.getenv(name, default)
    return v.strip() if isinstance(v, str) else v

def _get_public_ipv4() -> str:
    # Fast, AWS-hosted IP echo
    return requests.get("https://checkip.amazonaws.com/", timeout=10).text.strip()

def _get_public_ipv6() -> str:
    # Only if you actually have global v6
    return requests.get("https://ifconfig.co/ip", headers={"Accept":"text/plain"}, timeout=10).text.strip()

def _current_record_ip(route53, hosted_zone_id: str, name: str, rtype: str) -> Optional[str]:
    """Fetch current value of the record (first value only)."""
    try:
        resp = route53.list_resource_record_sets(
            HostedZoneId=hosted_zone_id,
            StartRecordName=name,
            StartRecordType=rtype,
            MaxItems="1",
        )
        rrsets = resp.get("ResourceRecordSets", [])
        if rrsets and rrsets[0]["Name"].rstrip(".").lower() == name.rstrip(".").lower() \
           and rrsets[0]["Type"] == rtype:
            vals = [r["Value"] for r in rrsets[0].get("ResourceRecords", [])]
            return vals[0] if vals else None
        return None
    except botocore.exceptions.ClientError as e:
        log.warning(f"Could not read existing {rtype} for {name}: {e}")
        return None

def _upsert_record(route53, hosted_zone_id: str, name: str, rtype: str, value: str, ttl: int = 300) -> str:
    """UPSERT A/AAAA record to the given value; returns change ID."""
    change = {
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "Name": name,
            "Type": rtype,
            "TTL": ttl,
            "ResourceRecords": [{"Value": value}],
        },
    }
    resp = route53.change_resource_record_sets(
        HostedZoneId=hosted_zone_id,
        ChangeBatch={"Comment": f"ddns update for {name} -> {value}", "Changes": [change]},
    )
    return resp["ChangeInfo"]["Id"]  # e.g. /change/C12345ABCDE

def _wait_insync(route53, change_id: str, timeout_s: int = 60):
    """Optional: wait until INSYNC (usually seconds)."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        st = route53.get_change(Id=change_id)["ChangeInfo"]["Status"]
        if st == "INSYNC":
            return
        time.sleep(2)
    log.warning(f"Route53 change {change_id} not INSYNC after {timeout_s}s")

def run():
    hosted_zone_id = _env("R53_HOSTED_ZONE_ID")
    dns_name       = _env("R53_DNS_NAME")
    ttl            = int(_env("R53_TTL", "300"))
    want_ipv6      = _env("R53_IPV6", "false").lower() in ("1", "true", "yes")

    if not (hosted_zone_id and dns_name):
        log.warning("DDNS: R53_HOSTED_ZONE_ID or R53_DNS_NAME missing; skipping.")
        return

    route53 = boto3.client("route53", region_name=_env("AWS_REGION"))  # region optional for Route53

    # --- IPv4 ---
    try:
        new_ip4 = _get_public_ipv4()
    except Exception as e:
        log.error(f"DDNS: failed to fetch public IPv4: {e}")
        return

    cur_ip4 = _current_record_ip(route53, hosted_zone_id, dns_name, "A")
    if cur_ip4 == new_ip4:
        log.info(f"DDNS: A {dns_name} already {new_ip4}; no change.")
    else:
        try:
            cid = _upsert_record(route53, hosted_zone_id, dns_name, "A", new_ip4, ttl)
            _wait_insync(route53, cid, timeout_s=60)
            log.info(f"DDNS: updated A {dns_name} -> {new_ip4}")
        except botocore.exceptions.ClientError as e:
            raise RuntimeError(f"Route53 A update error: {e}") from e

    # --- IPv6 (optional) ---
    if want_ipv6:
        try:
            new_ip6 = _get_public_ipv6()
            cur_ip6 = _current_record_ip(route53, hosted_zone_id, dns_name, "AAAA")
            if cur_ip6 == new_ip6:
                log.info(f"DDNS: AAAA {dns_name} already {new_ip6}; no change.")
            else:
                cid6 = _upsert_record(route53, hosted_zone_id, dns_name, "AAAA", new_ip6, ttl)
                _wait_insync(route53, cid6, timeout_s=60)
                log.info(f"DDNS: updated AAAA {dns_name} -> {new_ip6}")
        except Exception as e:
            # Don’t fail the whole job if v6 is flaky; just log.
            log.warning(f"DDNS: skipping IPv6 update: {e}")
