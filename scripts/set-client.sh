#!/usr/bin/env bash
# watchmen-set-client — Update the client/site labels on an installed dashboard.
#
# The installed dashboard at /var/lib/watchmen-web/index.html has the
# client/site names baked in at install time. Use this script to change them
# later without a full reinstall.
#
# Usage:
#   sudo watchmen-set-client "Pat Gallager" "Surfside 6H"
#   sudo watchmen-set-client "Acme Corp"            # site defaults to hostname
#   sudo watchmen-set-client                        # interactive prompt

set -euo pipefail

DASHBOARD="/var/lib/watchmen-web/index.html"

if [[ ! -f "$DASHBOARD" ]]; then
    echo "error: dashboard not found at $DASHBOARD" >&2
    echo "is watchmen installed?" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root (the dashboard file is in /var/lib)" >&2
    exit 1
fi

client_name="${1:-}"
site_name="${2:-}"

if [[ -z "$client_name" && -t 0 ]]; then
    # Show current values from the dashboard
    current_client=$(grep -oE 'id="client-name">[^<]*' "$DASHBOARD" | head -1 | sed 's/id="client-name">//')
    current_site=$(grep -oE 'id="site-name">[^<]*' "$DASHBOARD" | head -1 | sed 's/id="site-name">//')
    echo "Current client: ${current_client:-<unset>}"
    echo "Current site:   ${current_site:-<unset>}"
    echo
    read -p "New client name: " client_name
    read -p "New site name:   " site_name
fi

site_name="${site_name:-$(hostname)}"
client_name="${client_name:-APC UPS Fleet}"

# Update the markup, replacing whatever's currently between the spans
sed -i -E "s|(<span id=\"client-name\">)[^<]*(</span>)|\\1$(printf '%s' "$client_name" | sed 's/[\\&|]/\\&/g')\\2|" "$DASHBOARD"
sed -i -E "s|(id=\"site-name\">)[^<]*(</div>)|\\1$(printf '%s' "$site_name" | sed 's/[\\&|]/\\&/g')\\2|" "$DASHBOARD"

echo "Updated:"
echo "  Client: $client_name"
echo "  Site:   $site_name"
echo
echo "Refresh the dashboard in your browser to see the change."
