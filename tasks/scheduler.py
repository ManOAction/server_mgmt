import sys, signal, logging
from apscheduler.schedulers.blocking import BlockingScheduler
from apscheduler.triggers.interval import IntervalTrigger
from config import settings
from jobs import hello, ddns_route53, certbot_renewal

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("tasks.scheduler")
sched = BlockingScheduler()

# Register jobs
sched.add_job(hello.run,         IntervalTrigger(minutes=settings.HELLO_INTERVAL_MIN), id="hello")
sched.add_job(ddns_route53.run, IntervalTrigger(minutes=settings.DDNS_INTERVAL_MIN), id="ddns")

# Certificate renewal - run daily at 2:30 AM
# Certbot will only renew certificates within 30 days of expiration
sched.add_job(
    certbot_renewal.run,
    IntervalTrigger(hours=24),
    id="cert_renewal",
    max_instances=1  # Prevent overlapping runs
)

# Optional: Weekly certificate status check
sched.add_job(
    certbot_renewal.test_certificates,
    IntervalTrigger(hours=168),  # 168 hours = 7 days
    id="cert_status_check"
)


def _sigterm(*_):
    log.info("SIGTERM received, shutting down scheduler...")
    try: sched.shutdown(wait=False)
    finally: sys.exit(0)

signal.signal(signal.SIGTERM, _sigterm)

if __name__ == "__main__":
    log.info(f"Starting scheduler (hello {settings.HELLO_INTERVAL_MIN}m, ddns {settings.DDNS_INTERVAL_MIN}m)")
    sched.start()
