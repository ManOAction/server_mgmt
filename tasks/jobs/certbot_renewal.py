import docker
import logging
import os

log = logging.getLogger("tasks.jobs.certbot_renewal")

def run():
    """
    Renew Let's Encrypt certificates using Docker API and reload nginx if successful.

    This job should run daily. Certbot will only renew certificates that are
    within 30 days of expiration, so running daily is safe and recommended.
    """
    try:
        log.info("Starting certificate renewal process...")

        # Connect to Docker daemon
        client = docker.from_env()

        # Get project name from environment or default
        project_name = os.getenv("COMPOSE_PROJECT_NAME", "server_mgmt")
        network_name = f"{project_name}_default"

        # Find the certbot image (built by docker-compose)
        try:
            images = client.images.list()
            certbot_image = None
            for img in images:
                if img.tags and any(f"{project_name}" in tag and "certbot" in tag for tag in img.tags):
                    certbot_image = img.tags[0]
                    break

            if not certbot_image:
                # Fallback to generic certbot image
                certbot_image = "certbot/certbot"
                log.warning(f"Custom certbot image not found, using {certbot_image}")

            log.info(f"Using certbot image: {certbot_image}")

        except Exception as e:
            log.error(f"Error finding certbot image: {e}")
            return

        # Get volumes from existing setup
        try:
            # Try to find an existing certbot container to get volume info
            containers = client.containers.list(
                all=True,
                filters={
                    "label": f"com.docker.compose.project={project_name}",
                    "label": "com.docker.compose.service=certbot"
                }
            )

            volumes = {}
            if containers:
                # Use volumes from existing certbot container
                for mount in containers[0].attrs['Mounts']:
                    if mount['Type'] == 'volume':
                        volumes[mount['Name']] = {'bind': mount['Destination'], 'mode': 'rw'}
                    elif mount['Type'] == 'bind':
                        volumes[mount['Source']] = {'bind': mount['Destination'], 'mode': mount.get('Mode', 'rw')}
            else:
                # Fallback to expected volume setup
                volumes = {
                    f"{project_name}_certbot-certs": {'bind': '/etc/letsencrypt', 'mode': 'rw'}
                }

            log.debug(f"Using volumes: {volumes}")

        except Exception as e:
            log.error(f"Error getting volume configuration: {e}")
            return

        # Run certbot renewal
        log.info("Running certbot renewal container...")
        try:
            container = client.containers.run(
                image=certbot_image,
                command=["renew"],
                volumes=volumes,
                network=network_name,
                remove=True,
                detach=False,
                environment=_get_certbot_environment(),
                stdout=True,
                stderr=True
            )

            # container is the output when detach=False
            output = container.decode('utf-8') if isinstance(container, bytes) else str(container)
            log.info("Certificate renewal completed successfully")
            log.debug(f"Certbot output: {output}")

            # Check if any certificates were actually renewed
            if "No renewals were attempted" in output:
                log.info("No certificates needed renewal")
                return

            if "Congratulations, all renewals succeeded" in output:
                log.info("Certificates were renewed, reloading nginx...")
                _reload_nginx(client, project_name)
            else:
                log.info("Certificate renewal check completed, no action needed")

        except docker.errors.ContainerError as e:
            log.error(f"Certbot container failed with exit code {e.exit_status}")
            log.error(f"Certbot error output: {e.stderr.decode() if e.stderr else 'No stderr'}")

    except docker.errors.DockerException as e:
        log.error(f"Docker API error during certificate renewal: {e}")
    except Exception as e:
        log.error(f"Unexpected error during certificate renewal: {e}")

def _get_certbot_environment():
    """Get environment variables needed for certbot (like AWS credentials for Route53)"""
    env = {}

    # Pass through AWS credentials for Route53 DNS challenge
    aws_vars = ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_DEFAULT_REGION']
    for var in aws_vars:
        if var in os.environ:
            env[var] = os.environ[var]

    return env

def _reload_nginx(client, project_name):
    """Reload nginx configuration to use new certificates"""
    try:
        # Find nginx container
        containers = client.containers.list(
            filters={
                "label": f"com.docker.compose.project={project_name}",
                "label": "com.docker.compose.service=nginx"
            }
        )

        if not containers:
            log.error("Nginx container not found")
            return

        nginx_container = containers[0]
        result = nginx_container.exec_run("nginx -s reload")

        if result.exit_code == 0:
            log.info("Nginx reloaded successfully")
        else:
            error_output = result.output.decode() if result.output else "No output"
            log.error(f"Failed to reload nginx (exit code {result.exit_code}): {error_output}")

    except Exception as e:
        log.error(f"Error reloading nginx: {e}")

def test_certificates():
    """
    Test certificate validity and expiration dates.
    Useful for monitoring certificate health.
    """
    try:
        log.info("Checking certificate status...")

        client = docker.from_env()
        project_name = os.getenv("COMPOSE_PROJECT_NAME", "server_mgmt")
        network_name = f"{project_name}_default"

        # Find certbot image
        images = client.images.list()
        certbot_image = None
        for img in images:
            if img.tags and any(f"{project_name}" in tag and "certbot" in tag for tag in img.tags):
                certbot_image = img.tags[0]
                break

        if not certbot_image:
            certbot_image = "certbot/certbot"

        # Get volumes (same as renewal function)
        containers = client.containers.list(
            all=True,
            filters={
                "label": f"com.docker.compose.project={project_name}",
                "label": "com.docker.compose.service=certbot"
            }
        )

        volumes = {}
        if containers:
            for mount in containers[0].attrs['Mounts']:
                if mount['Type'] == 'volume':
                    volumes[mount['Name']] = {'bind': mount['Destination'], 'mode': 'rw'}
                elif mount['Type'] == 'bind':
                    volumes[mount['Source']] = {'bind': mount['Destination'], 'mode': mount.get('Mode', 'rw')}
        else:
            volumes = {f"{project_name}_certbot-certs": {'bind': '/etc/letsencrypt', 'mode': 'rw'}}

        # Run certificate status check
        container = client.containers.run(
            image=certbot_image,
            command=["certificates"],
            volumes=volumes,
            network=network_name,
            remove=True,
            detach=False,
            environment=_get_certbot_environment()
        )

        output = container.decode('utf-8') if isinstance(container, bytes) else str(container)
        log.info("Certificate status check completed")
        log.info(f"Certificate info:\n{output}")

    except Exception as e:
        log.error(f"Error checking certificate status: {e}")

def restart_container(service_name):
    """
    Restart a specific service container - useful for maintenance
    """
    try:
        client = docker.from_env()
        project_name = os.getenv("COMPOSE_PROJECT_NAME", "server_mgmt")

        containers = client.containers.list(
            filters={
                "label": f"com.docker.compose.project={project_name}",
                "label": f"com.docker.compose.service={service_name}"
            }
        )

        if not containers:
            log.error(f"No containers found for service: {service_name}")
            return

        for container in containers:
            container.restart()
            log.info(f"Restarted container: {container.name}")

    except Exception as e:
        log.error(f"Failed to restart service {service_name}: {e}")

def get_container_status():
    """
    Get status of all containers in the project
    """
    try:
        client = docker.from_env()
        project_name = os.getenv("COMPOSE_PROJECT_NAME", "server_mgmt")

        containers = client.containers.list(
            all=True,
            filters={"label": f"com.docker.compose.project={project_name}"}
        )

        status = {}
        for container in containers:
            service_name = container.labels.get("com.docker.compose.service", "unknown")
            status[service_name] = {
                "status": container.status,
                "name": container.name,
                "id": container.short_id,
                "image": container.image.tags[0] if container.image.tags else "unknown"
            }

        log.info("Container status:")
        for service, info in status.items():
            log.info(f"  {service}: {info['status']} ({info['name']})")

        return status

    except Exception as e:
        log.error(f"Failed to get container status: {e}")
        return {}

if __name__ == "__main__":
    # For testing
    logging.basicConfig(level=logging.INFO)
    run()