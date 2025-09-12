import logging
log = logging.getLogger("tasks.hello")

def run():
    log.info("Hello World from APScheduler — tasks container is alive.")
