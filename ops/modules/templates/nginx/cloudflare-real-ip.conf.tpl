# Cloudflare Real IP snippet for Nginx
# Source: https://www.cloudflare.com/ips/
# Include this snippet in your server {} block:
#   include /etc/nginx/snippets/cloudflare-real-ip.conf;
#
# Managed by OPS. Real IP ranges below are generated from Cloudflare's published
# IPv4/IPv6 lists at enable/refresh time.
# Last refreshed: {{LAST_REFRESH}}

{{REAL_IP_RANGES}}
real_ip_header CF-Connecting-IP;
