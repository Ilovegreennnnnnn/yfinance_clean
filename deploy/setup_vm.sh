#!/bin/bash
# deploy/setup_vm.sh
# Exécuter en tant que root (sudo bash setup_vm.sh)
# Ubuntu 22.04 LTS sur Oracle ARM A1

set -e  # Stopper si erreur

echo "=== 1. Mise à jour système ==="
apt-get update -qq
apt-get upgrade -y -qq

echo "=== 2. Installation Python 3.11 ==="
apt-get install -y python3.11 python3.11-venv python3.11-dev
apt-get install -y python3-pip
update-alternatives --install /usr/bin/python3 python3 \
  /usr/bin/python3.11 1

echo "=== 3. Installation outils système ==="
apt-get install -y git curl wget unzip nginx certbot \
  python3-certbot-nginx

echo "=== 4. Création user peaquant ==="
useradd -m -s /bin/bash peaquant || echo "User existe déjà"

echo "=== 5. Création structure répertoires ==="
mkdir -p /app/pea-quant
mkdir -p /wallet
mkdir -p /var/log/pea-quant
chown -R peaquant:peaquant /app/pea-quant
chown -R peaquant:peaquant /wallet
chown -R peaquant:peaquant /var/log/pea-quant
chmod 700 /wallet

echo "=== 6. Création venv Python ==="
sudo -u peaquant python3.11 -m venv /app/pea-quant/venv

echo "=== 7. Droits sudo limités pour peaquant ==="
cat > /etc/sudoers.d/peaquant << 'EOF'
peaquant ALL=(ALL) NOPASSWD: /bin/systemctl restart pea-dashboard
peaquant ALL=(ALL) NOPASSWD: /bin/systemctl status pea-dashboard
peaquant ALL=(ALL) NOPASSWD: /bin/systemctl stop pea-dashboard
EOF
chmod 440 /etc/sudoers.d/peaquant

echo "=== 8. Configuration Nginx ==="
cat > /etc/nginx/sites-available/pea-quant << 'EOF'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    # Certificats Let's Encrypt (configurés par certbot après)
    # ssl_certificate /etc/letsencrypt/live/domain/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/domain/privkey.pem;

    # Pour commencer sans domaine (HTTP seulement)
    # Commenter le bloc 443 et utiliser le port 8501 directement

    location / {
        proxy_pass http://127.0.0.1:8501;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
EOF
ln -sf /etc/nginx/sites-available/pea-quant \
  /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

echo "=== 9. Service systemd Streamlit ==="
cat > /etc/systemd/system/pea-dashboard.service << 'EOF'
[Unit]
Description=PEA Quant Dashboard Streamlit
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=peaquant
Group=peaquant
WorkingDirectory=/app/pea-quant
ExecStart=/app/pea-quant/venv/bin/streamlit run dashboard/app.py \
  --server.port 8501 \
  --server.address 127.0.0.1 \
  --server.headless true \
  --server.fileWatcherType none \
  --browser.gatherUsageStats false
Restart=always
RestartSec=10
EnvironmentFile=/app/pea-quant/.env
StandardOutput=append:/var/log/pea-quant/streamlit.log
StandardError=append:/var/log/pea-quant/streamlit.log

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable pea-dashboard

echo "=== 10. Configuration logrotate ==="
cat > /etc/logrotate.d/pea-quant << 'EOF'
/var/log/pea-quant/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0644 peaquant peaquant
}
EOF

echo "=== 11. Firewall ==="
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "=== 12. Crontab pour peaquant ==="
cat > /tmp/peaquant_crontab << 'EOF'
# Pipeline quotidien lun-ven
00 19 * * 1-5 cd /app/pea-quant && \
  /app/pea-quant/venv/bin/python scheduler/pipeline.py \
  >> /var/log/pea-quant/pipeline.log 2>&1

# Intégrité hebdomadaire dimanche
00 10 * * 0 cd /app/pea-quant && \
  /app/pea-quant/venv/bin/python scripts/integrity_check.py \
  >> /var/log/pea-quant/integrity.log 2>&1

# Rappel mise à jour tickers (1er du trimestre)
00 09 1 1,4,7,10 * cd /app/pea-quant && \
  /app/pea-quant/venv/bin/python scripts/ticker_reminder.py \
  >> /var/log/pea-quant/integrity.log 2>&1

# Renouvellement SSL
00 03 * * * certbot renew --quiet
EOF
crontab -u peaquant /tmp/peaquant_crontab
rm /tmp/peaquant_crontab

echo "=== SETUP TERMINÉ ==="
echo "Prochaines étapes manuelles :"
echo "1. Uploader Wallet Oracle dans /wallet/"
