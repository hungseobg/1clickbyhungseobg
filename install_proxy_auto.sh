#!/usr/bin/env bash
# Auto-install HTTPS proxy (Squid) on Ubuntu 25.04 (GNU/Linux 6.14.0-1006-gcp x86_64)
# 100% automatic: install, configure auth, firewall, and start service

set -e

# 1. Kiểm tra quyền root
if [ "$(id -u)" -ne 0 ]; then
  echo "Vui lòng chạy script với quyền root (sudo)."
  exit 1
fi

# 2. Lấy IP công khai
PUBLIC_IP=$(curl -4s https://api.ipify.org)
if [ -z "$PUBLIC_IP" ]; then
  echo "Không lấy được IP công khai. Vui lòng kiểm tra kết nối." >&2
  exit 1
fi

# 3. Khởi tạo biến\ USER/pass/port\ SCRIPT
USER="proxy_$(tr -dc 'a-z0-9' </dev/urandom | head -c6)"
PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c12)"
PORT=3128

# 4. Cài đặt gói cần thiết
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y squid apache2-utils ufw

# 5. Cấu hình UFW
ufw allow ssh
ufw allow ${PORT}/tcp
ufw --force enable

# 6. Tạo file mật khẩu cho Squid
htpasswd -b -c /etc/squid/passwd $USER $PASSWORD

# 7. Backup cấu hình cũ và viết mới
cp /etc/squid/squid.conf /etc/squid/squid.conf.bak.$(date +%Y%m%d%H%M%S)
cat > /etc/squid/squid.conf <<EOF
# Squid HTTPS proxy tự động cài đặt

auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
auth_param basic realm Proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated

# Cổng proxy
http_port ${PORT}

# Tắt caching
cache deny all

# Log
access_log /var/log/squid/access.log
cache_log /var/log/squid/cache.log
coredump_dir /var/spool/squid
EOF

# 8. Khởi động và enable dịch vụ Squid
systemctl restart squid
systemctl enable squid

# 9. Hoàn thành và in thông tin kết nối
cat <<EOF
========================
HTTPS proxy đã sẵn sàng!
URL proxy:
  http://${USER}:${PASSWORD}@${PUBLIC_IP}:${PORT}
========================
EOF
# 9. Display connection information
echo "========================================"
echo "Hùng Sẹo BG"
echo "========================================"

