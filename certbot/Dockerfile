FROM certbot/certbot

# Install Route 53 DNS challenge plugin
RUN pip install certbot-dns-route53

# The Route 53 plugin uses AWS credentials from environment variables
# No need for credential files with Route 53