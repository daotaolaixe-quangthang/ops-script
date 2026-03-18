# Custom X-Powered-By header snippet for Nginx
# Include this snippet in your server {} or http {} block:
#   include /etc/nginx/snippets/custom-powered-by.conf;
#
# NOTE: This uses the standard Nginx add_header directive.
# The default PHP X-Powered-By header is hidden via php.ini:
#   expose_php = Off
#
# Replace {{VALUE}} with your desired header value before deploying.

add_header X-Powered-By "{{VALUE}}" always;
