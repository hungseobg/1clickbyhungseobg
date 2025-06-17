#!/usr/bin/env bash
# Combined installer for SOCKS5 (Dante), Shadowsocks-libev, and HTTPS proxy (Squid)
# Supports Ubuntu/Debian and RedHat-based distributions

set -e

# ==================================================================================
#                            🌐 Firewall (UFW) Setup
# ==================================================================================
# Automatic installation and enabling of UFW on Debian/Ubuntu
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
        echo "🔧 Installing UFW firewall..."
        apt-get update >/dev/null 2>&1
        apt-get install -y ufw >/dev/null 2>&1
        ufw allow ssh >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
        echo "✅ UFW installed and enabled"
    fi
fi

# Detect OS type
OS=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian) OS="debian" ;;        
        amzn|centos|rhel|rocky|almalinux) OS="redhat" ;;        
        *) echo "❌ Unsupported OS: $ID"; exit 1 ;;    
    esac
else
    echo "❌ Cannot detect OS."; exit 1
fi

# User selections
echo "Select server(s) to install:"
echo "  1) SOCKS5 (Dante)"
echo "  2) Shadowsocks-libev"
echo "  3) Both SOCKS5 & Shadowsocks"
echo "  4) HTTPS proxy (Squid)"
read -p "Enter choice [1-4]: " choice

echo ""
echo "Select configuration mode:"
echo "  1) Automatic (random credentials)"
echo "  2) Manual (custom credentials)"
read -p "Enter choice [1 or 2]: " config_mode

# Network info
EXT_IF=$(ip route | awk '/default/ {print $5; exit}')
EXT_IF=${EXT_IF:-eth0}
PUBLIC_IP=$(curl -4 -s https://api.ipify.org)

# Manual credential prompts
get_manual_socks5_credentials() {
    read -p "Enter SOCKS5 port (default: 443): " MANUAL_PORT
    MANUAL_PORT=${MANUAL_PORT:-443}
    read -p "Enter SOCKS5 username (default: cr4ckpwd): " MANUAL_USERNAME
    MANUAL_USERNAME=${MANUAL_USERNAME:-cr4ckpwd}
    read -p "Enter SOCKS5 password (default: vunghiabui): " MANUAL_PASSWORD
    MANUAL_PASSWORD=${MANUAL_PASSWORD:-vunghiabui}
}

get_manual_shadowsocks_credentials() {
    read -p "Enter Shadowsocks port (default: 443): " MANUAL_SS_PORT
    MANUAL_SS_PORT=${MANUAL_SS_PORT:-443}
    read -p "Enter Shadowsocks password (default: vunghiabui): " MANUAL_SS_PASSWORD
    MANUAL_SS_PASSWORD=${MANUAL_SS_PASSWORD:-vunghiabui}
}

get_manual_https_credentials() {
    read -p "Enter HTTPS proxy port (default: 3128): " MANUAL_HTTPS_PORT
    MANUAL_HTTPS_PORT=${MANUAL_HTTPS_PORT:-3128}
    read -p "Enter HTTPS proxy username (default: proxyuser): " MANUAL_HTTPS_USER
    MANUAL_HTTPS_USER=${MANUAL_HTTPS_USER:-proxyuser}
    read -p "Enter HTTPS proxy password (default: proxypass): " MANUAL_HTTPS_PASS
    MANUAL_HTTPS_PASS=${MANUAL_HTTPS_PASS:-proxypass}
}

# Install SOCKS5 (Dante)
install_socks5() {
    local USERNAME PASSWORD PORT
    if [ "$config_mode" = "1" ]; then
        USERNAME="user_$(tr -dc 'a-z0-9' </dev/urandom | head -c8)"
        PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c12)"
        PORT=$(shuf -i 1025-65000 -n1)
    else
        get_manual_socks5_credentials
        USERNAME="$MANUAL_USERNAME"
        PASSWORD="$MANUAL_PASSWORD"
        PORT="$MANUAL_PORT"
    fi
    if [ "$OS" = "debian" ]; then
        apt-get update >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y dante-server curl iptables iptables-persistent >/dev/null 2>&1
    else
        yum install -y epel-release >/dev/null 2>&1
        yum install -y dante-server curl iptables-services >/dev/null 2>&1
        systemctl enable iptables >/dev/null 2>&1
        systemctl start iptables >/dev/null 2>&1
    fi
    useradd -M -N -s /usr/sbin/nologin "$USERNAME" >/dev/null 2>&1 || true
    echo "${USERNAME}:${PASSWORD}" | chpasswd >/dev/null 2>&1
    cat > /etc/danted.conf <<EOF
logoutput: syslog /var/log/danted.log
internal: 0.0.0.0 port = ${PORT}
external: ${EXT_IF}
method: pam
user.privileged: root
user.notprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 command: bind connect udpassociate }
EOF
    chmod 644 /etc/danted.conf
    systemctl restart danted >/dev/null 2>&1
    systemctl enable danted >/dev/null 2>&1
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${PORT}/tcp" >/dev/null 2>&1
    else
        iptables -I INPUT -p tcp --dport "${PORT}" -j ACCEPT >/dev/null 2>&1
        iptables-save > /etc/iptables/rules.v4 >/dev/null 2>&1 || true
    fi
    echo "socks5://${PUBLIC_IP}:${PORT}:${USERNAME}:${PASSWORD}"
}

# Install Shadowsocks
install_shadowsocks() {
    local PASSWORD SERVER_PORT METHOD="aes-256-gcm"
    if [ "$config_mode" = "1" ]; then
        PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c16)
        SERVER_PORT=$((RANDOM % 50000 + 10000))
    else
        get_manual_shadowsocks_credentials
        PASSWORD="$MANUAL_SS_PASSWORD"
        SERVER_PORT="$MANUAL_SS_PORT"
    fi
    if [ "$OS" = "debian" ]; then
        apt-get update >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y shadowsocks-libev qrencode curl iptables iptables-persistent >/dev/null 2>&1
    else
        yum install -y epel-release >/dev/null 2>&1
        yum install -y shadowsocks-libev qrencode curl firewalld >/dev/null 2>&1
        systemctl enable firewalld >/dev/null 2>&1
        systemctl start firewalld >/dev/null 2>&1
    fi
    cat > /etc/shadowsocks-libev/config.json <<EOF
{
  "server":"0.0.0.0",
  "server_port":${SERVER_PORT},
  "password":"${PASSWORD}",
  "timeout":300,
  "method":"${METHOD}",
  "fast_open": false,
  "nameserver":"1.1.1.1",
  "mode":"tcp_and_udp"
}
EOF
    if [ "$OS" = "debian" ]; then
        if command -v ufw >/dev/null 2>&1; then
            ufw allow ${SERVER_PORT}/tcp >/dev/null 2>&1
            ufw allow ${SERVER_PORT}/udp >/dev/null 2>&1
        else
            iptables -I INPUT -p tcp --dport ${SERVER_PORT} -j ACCEPT >/dev/null 2>&1
            iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT >/dev/null 2>&1
            iptables-save > /etc/iptables/rules.v4 >/dev/null 2>&1 || true
        fi
    else
        firewall-cmd --permanent --add-port=${SERVER_PORT}/tcp >/dev/null 2>&1
        firewall-cmd --permanent --add-port=${SERVER_PORT}/udp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    systemctl enable shadowsocks-libev >/dev/null 2>&1
    systemctl restart shadowsocks-libev >/dev/null 2>&1
    echo "shadowsocks://${PUBLIC_IP}:${SERVER_PORT}:${METHOD}:${PASSWORD}"
}

# Install HTTPS proxy (Squid)
install_https_proxy() {
    local PORT USER PASS
    if [ "$config_mode" = "1" ]; then
        PORT=3128
        USER=user_https_$(tr -dc 'a-z0-9' </dev/urandom | head -c6)
        PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c10)
    else
        get_manual_https_credentials
        PORT="$MANUAL_HTTPS_PORT"
        USER="$MANUAL_HTTPS_USER"
        PASS="$MANUAL_HTTPS_PASS"
    fi
    if [ "$OS" = "debian" ]; then
        apt-get update >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y squid apache2-utils >/dev/null 2>&1
    else
        yum install -y squid httpd-tools >/dev/null 2>&1
    fi
    htpasswd -b -c /etc/squid/passwd "$USER" "$PASS"
    cp /etc/squid/squid.conf /etc/squid/squid.conf.bak.$(date +%F_%T) >/dev/null 2>&1 || true
    cat > /etc/squid/squid.conf <<EOF
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
auth_param basic realm proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_port ${PORT}
cache deny all
EOF
    systemctl restart squid >/dev/null 2>&1
    systemctl enable squid >/dev/null 2>&1
    if command -v ufw >/dev/null 2>&1; then
        ufw allow ${PORT}/tcp >/dev/null 2>&1
    else
        iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT >/dev/null 2>&1
        iptables-save > /etc/iptables/rules.v4 >/dev/null 2>&1 || true
    fi
    echo "http://${USER}:${PASS}@${PUBLIC_IP}:${PORT}"
}

# Main logic
case "$choice" in
    1)
        echo "🚀 Installing SOCKS5 server..."
        info=$(install_socks5)
        draw_box "🧦 SOCKS5 PROXY SERVER" "$info"
        ;;
    2)
        echo "🚀 Installing Shadowsocks server..."
        info=$(install_shadowsocks)
        draw_box "👻 SHADOWSOCKS SERVER" "$info"
        ;;
    3)
        echo "🚀 Installing both SOCKS5 and Shadowsocks servers..."
        socks_info=$(install_socks5)
        ss_info=$(install_shadowsocks)
        combined="${socks_info}\n${ss_info}"
        draw_box "🚀 PROXY SERVERS INSTALLED" "$combined"
        ;;
    4)
        echo "🚀 Installing HTTPS proxy (Squid)..."
        info=$(install_https_proxy)
        draw_box "🔐 HTTPS PROXY SERVER" "$info"
        ;;
    *)
        echo "❌ Invalid choice"
        exit 1
        ;;
esac
