#!/usr/bin/env bash
# Automated installer for HTTPS (Squid) and SOCKS5 (Dante) proxies on Ubuntu/Debian/RedHat
# Designed to run non-interactively via curl -O with fixed ports: HTTPS (55000), SOCKS5 (1080)

set -e

# Output file for proxy configuration
OUTPUT_FILE="/root/proxy_config.txt"

# Function to draw box around text (for output file and console)
draw_box() {
    local title="$1"
    local content="$2"
    local width=60
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m'
    local BOLD='\033[1m'
    local box_output=""
    
    box_output+="\n"
    box_output+="${GREEN}┌$(printf '─%.0s' $(seq 1 $((width-2))))┐${NC}\n"
    box_output+="${GREEN}│${BOLD}${YELLOW} $(printf "%-*s" $((width-4)) "$title") ${NC}${GREEN}│${NC}\n"
    box_output+="${GREEN}├$(printf '─%.0s' $(seq 1 $((width-2))))┤${NC}\n"
    
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            box_output+="${GREEN}│${NC} $(printf "%-*s" $((width-4)) "$line") ${GREEN}│${NC}\n"
        fi
    done <<< "$content"
    
    box_output+="${GREEN}└$(printf '─%.0s' $(seq 1 $((width-2))))┘${NC}\n"
    
    # Print to console and save to file
    echo -e "$box_output"
    echo -e "$box_output" >> "$OUTPUT_FILE"
}

# Function to check if port is in use
check_port() {
    local port="$1"
    if ss -tuln | grep -q ":${port}\b"; then
        echo "❌ Port ${port} is already in use." | tee -a "$OUTPUT_FILE"
        exit 1
    fi
}

# Function to create GCP firewall rule
create_gcp_firewall_rule() {
    local rule_name="$1"
    local port="$2"
    local target_tag="http-server"
    gcloud compute firewall-rules create "$rule_name" \
        --network default \
        --priority 1000 \
        --direction INGRESS \
        --action ALLOW \
        --target-tags "$target_tag" \
        --source-ranges "$ALLOWED_IPS" \
        --allow tcp:"$port" >/dev/null 2>&1 || echo "⚠️ Failed to create GCP firewall rule $rule_name" | tee -a "$OUTPUT_FILE"
}

# Detect OS
OS=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian) OS="debian" ;;
        amzn|centos|rhel|rocky|almalinux) OS="redhat" ;;
        *) echo "❌ Unsupported OS: $ID" | tee -a "$OUTPUT_FILE"; exit 1 ;;
    esac
else
    echo "❌ Cannot detect OS." | tee -a "$OUTPUT_FILE"
    exit 1
fi

# Get network interface and public IP
EXT_IF=$(ip route | awk '/default/ {print $5; exit}')
EXT_IF=${EXT_IF:-eth0}
PUBLIC_IP=$(curl -4 -s https://api.ipify.org)
if [ -z "$PUBLIC_IP" ]; then
    echo "❌ Failed to get public IP." | tee -a "$OUTPUT_FILE"
    exit 1
fi

# Default configuration
CHOICE=3  # Install both HTTPS and SOCKS5
CONFIG_MODE=1  # Automatic mode
ALLOWED_IPS="0.0.0.0/0"  # Allow all IPs

# Function to install HTTPS proxy (Squid)
install_https() {
    local USERNAME="proxy_$(tr -dc 'a-z0-9' </dev/urandom | head -c8)"
    local PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c12)"
    local PORT=55000  # Fixed port for HTTPS
    check_port "$PORT"

    echo "🚀 Installing HTTPS proxy on port $PORT..." | tee -a "$OUTPUT_FILE"

    # Install packages
    if [ "$OS" = "debian" ]; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y squid apache2-utils curl iptables iptables-persistent -qq
    else
        yum install -y epel-release -q
        yum install -y squid httpd-tools curl iptables-services -q
        systemctl enable iptables -q
        systemctl start iptables -q
    fi

    # Create user
    htpasswd -b -c /etc/squid/passwd "$USERNAME" "$PASSWORD" >/dev/null 2>&1

    # Configure Squid
    [ -f /etc/squid/squid.conf ] && cp /etc/squid/squid.conf /etc/squid/squid.conf.bak.$(date +%F_%T)
    cat > /etc/squid/squid.conf <<EOF
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
auth_param basic realm Proxy Authentication
acl authenticated proxy_auth REQUIRED
acl allowed_ips src $ALLOWED_IPS
http_access allow authenticated allowed_ips
http_access deny all
http_port 0.0.0.0:$PORT
EOF

    chmod 640 /etc/squid/passwd
    chown squid:squid /etc/squid/passwd
    systemctl restart squid >/dev/null 2>&1 || { echo "❌ Failed to start Squid" | tee -a "$OUTPUT_FILE"; exit 1; }
    systemctl enable squid >/dev/null 2>&1

    # Open local firewall
    if [ "$OS" = "debian" ]; then
        if command -v ufw >/dev/null 2>&1; then
            ufw allow "$PORT"/tcp >/dev/null 2>&1
        else
            iptables -I INPUT -p tcp --dport "$PORT" -s "$ALLOWED_IPS" -j ACCEPT >/dev/null 2>&1
            iptables-save > /etc/iptables/rules.v4 >/dev/null 2>&1
        fi
    else
        firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    # Open GCP firewall
    create_gcp_firewall_rule "allow-https-proxy-$PORT" "$PORT"

    # Check service status
    if ! systemctl is-active --quiet squid; then
        echo "❌ Squid service is not running." | tee -a "$OUTPUT_FILE"
        exit 1
    fi

    echo "https://$PUBLIC_IP:$PORT:$USERNAME:$PASSWORD"
}

# Function to install SOCKS5 (Dante)
install_socks5() {
    local USERNAME="socks_$(tr -dc 'a-z0-9' </dev/urandom | head -c8)"
    local PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c12)"
    local PORT=1080  # Fixed port for SOCKS5
    check_port "$PORT"

    echo "🚀 Installing SOCKS5 proxy on port $PORT..." | tee -a "$OUTPUT_FILE"

    # Install packages
    if [ "$OS" = "debian" ]; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server curl iptables iptables-persistent -qq
    else
        yum install -y epel-release -q
        yum install -y dante-server curl iptables-services -q
        systemctl enable iptables -q
        systemctl start iptables -q
    fi

    # Create user
    useradd -M -N -s /usr/sbin/nologin "$USERNAME" >/dev/null 2>&1 || true
    echo "${USERNAME}:${PASSWORD}" | chpasswd >/dev/null 2>&1

    # Configure Dante
    [ -f /etc/danted.conf ] && cp /etc/danted.conf /etc/danted.conf.bak.$(date +%F_%T)
    cat > /etc/danted.conf <<EOF
logoutput: syslog /var/log/danted.log
internal: 0.0.0.0 port = $PORT
external: $EXT_IF
method: pam
user.privileged: root
user.notprivileged: nobody
client pass {
    from: $ALLOWED_IPS to: 0.0.0.0/0
    log: connect disconnect error
}
socks pass {
    from: $ALLOWED_IPS to: 0.0.0.0/0
    command: bind connect udpassociate
    log: connect disconnect error
}
EOF

    chmod 644 /etc/danted.conf
    systemctl restart danted >/dev/null 2>&1 || { echo "❌ Failed to start Dante" | tee -a "$OUTPUT_FILE"; exit 1; }
    systemctl enable danted >/dev/null 2>&1

    # Open local firewall
    if [ "$OS" = "debian" ]; then
        if command -v ufw >/dev/null 2>&1; then
            ufw allow "$PORT"/tcp >/dev/null 2>&1
        else
            iptables -I INPUT -p tcp --dport "$PORT" -s "$ALLOWED_IPS" -j ACCEPT >/dev/null 2>&1
            iptables-save > /etc/iptables/rules.v4 >/dev/null 2>&1
        fi
    else
        firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi

    # Open GCP firewall
    create_gcp_firewall_rule "allow-socks5-proxy-$PORT" "$PORT"

    # Check service status
    if ! systemctl is-active --quiet danted; then
        echo "❌ Dante service is not running." | tee -a "$OUTPUT_FILE"
        exit 1
    fi

    echo "socks5://$PUBLIC_IP:$PORT:$USERNAME:$PASSWORD"
}

# Main logic
echo "🚀 Starting automated proxy installation..." | tee "$OUTPUT_FILE"

# Install both HTTPS and SOCKS5
https_info=$(install_https)
socks_info=$(install_socks5)
combined_info="${https_info}\n${socks_info}"
draw_box "🚀 PROXY SERVERS INSTALLED" "$combined_info"

echo "✅ Design by Hùng Sẹo BG." | tee -a "$OUTPUT_FILE"
