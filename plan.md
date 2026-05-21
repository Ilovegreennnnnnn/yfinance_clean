# Plan Complet Final — PEA Quant Swing Trader
## Version 3.0 — Agent-Ready

---

## Complément des Zones Grises

### ZG-1 — Deploy.yml : Séquence Exacte

```
PROBLÈME :
  systemctl restart nécessite sudo
  mais user peaquant n'a pas sudo complet
  et le venv doit être activé avant pip install

SOLUTION :
  1. Autoriser UNIQUEMENT systemctl restart pea-dashboard
     sans mot de passe pour user peaquant :
     
     Dans /etc/sudoers.d/peaquant (sur la VM, fait dans setup_vm.sh) :
     peaquant ALL=(ALL) NOPASSWD: /bin/systemctl restart pea-dashboard
     peaquant ALL=(ALL) NOPASSWD: /bin/systemctl status pea-dashboard
  
  2. Ne jamais "activer" le venv dans GitHub Actions
     Appeler directement les binaires du venv :
     /app/pea-quant/venv/bin/pip install ...
     /app/pea-quant/venv/bin/python scripts/migrate_db.py
     (pas besoin de source activate)

SÉQUENCE EXACTE deploy.yml :
  
  name: Deploy to Oracle VM
  on:
    push:
      branches: [main]
  jobs:
    deploy:
      runs-on: ubuntu-latest
      steps:
        - name: Deploy via SSH
          uses: appleboy/ssh-action@v1.0.0
          with:
            host: ${{ secrets.VM_HOST }}
            username: ${{ secrets.VM_USER }}
            key: ${{ secrets.VM_SSH_KEY }}
            script: |
              set -e
              
              # Aller dans le répertoire app
              cd /app/pea-quant
              
              # Récupérer le code
              git fetch origin main
              git reset --hard origin/main
              
              # Installer les dépendances dans le venv
              /app/pea-quant/venv/bin/pip install -r requirements.txt \
                --quiet --no-warn-script-location
              
              # Appliquer les migrations DB si nouvelles
              /app/pea-quant/venv/bin/python scripts/migrate_db.py
              
              # Restart le dashboard
              sudo /bin/systemctl restart pea-dashboard
              
              # Attendre que le service soit up
              sleep 15
              
              # Vérifier que le service tourne
              sudo /bin/systemctl status pea-dashboard \
                --no-pager | grep "active (running)"
              
              # Health check HTTP
              curl -f http://127.0.0.1:8501/_stcore/health \
                || exit 1
              
              echo "Deploy OK"

  Note : appleboy/ssh-action est gratuit et gère
         proprement les clés SSH multi-lignes depuis Secrets
```

---

### ZG-2 — Oracle Wallet : Setup Complet

```
CONTEXTE :
  Oracle Autonomous Database nécessite un Wallet pour se connecter
  Le Wallet est un dossier ZIP contenant plusieurs fichiers :
    cwallet.sso       → certificat auto-login
    ewallet.p12       → certificat PKCS12
    tnsnames.ora      → définition des connexions
    sqlnet.ora        → config réseau Oracle
    ojdbc.properties  → config JDBC (pas utile pour Python)
    README            → instructions Oracle

UTILISER python-oracledb EN MODE THIN :
  Mode thin = pas besoin d'Oracle Instant Client sur la VM
  Supporte Autonomous Database depuis python-oracledb v1.2
  
  Seuls fichiers nécessaires en mode thin :
    tnsnames.ora      → pour résoudre le DSN
    ewallet.p12       → pour le SSL
    (pas besoin de cwallet.sso en mode thin)

SETUP SUR LA VM (fait dans setup_vm.sh) :
  1. Créer dossier /wallet/
     mkdir -p /wallet
     chown peaquant:peaquant /wallet
     chmod 700 /wallet
  
  2. Uploader le wallet manuellement (1 seule fois) :
     Depuis votre machine locale :
     scp -i ssh_key Wallet_xxx.zip peaquant@VM_IP:/wallet/
     
     Sur la VM :
     cd /wallet && unzip Wallet_xxx.zip
     chmod 600 /wallet/*
  
  Note : Le wallet ne passe JAMAIS par GitHub
         C'est un fichier déposé manuellement sur la VM
         GitHub Secrets ne contient que les credentials texte

VARIABLES D'ENVIRONNEMENT sur la VM (/app/pea-quant/.env) :
  ORACLE_USER=ADMIN
  ORACLE_PASSWORD=votre_mot_de_passe
  ORACLE_DSN=votre_db_name_tp
  ORACLE_WALLET_PATH=/wallet
  ORACLE_WALLET_PASSWORD=votre_wallet_password
  
  Note : ORACLE_DSN = nom du service dans tnsnames.ora
         Regarder dans /wallet/tnsnames.ora les entrées disponibles
         Choisir l'entrée _tp (Transaction Processing)
         Ex : mondb_tp, mondb_low, mondb_high
         Pour notre usage : toujours _tp

CODE PYTHON de connexion (core/db.py) :
  import oracledb
  
  conn = oracledb.connect(
    user=config.ORACLE_USER,
    password=config.ORACLE_PASSWORD,
    dsn=config.ORACLE_DSN,
    wallet_location=config.ORACLE_WALLET_PATH,
    wallet_password=config.ORACLE_WALLET_PASSWORD
  )
  
  Note : pas d'init_oracle_client() en mode thin
         pas d'import de librairies C
         fonctionne sur ARM Ubuntu sans rien installer

DANS GITHUB ACTIONS (ci.yml) :
  Les tests unitaires ne se connectent PAS à Oracle
  Tous les tests DB utilisent des mocks
  Donc le wallet n'est pas nécessaire dans GitHub Actions
  
  Si un jour on veut des tests d'intégration :
    Stocker les 4 fichiers wallet encodés en base64
    dans GitHub Secrets séparément :
    WALLET_TNSNAMES_B64
    WALLET_EWALLET_B64
    WALLET_SQLNET_B64
    WALLET_CWALLET_B64
    Les décoder dans le step avant les tests
    Mais ce n'est PAS nécessaire pour le projet actuel
```

---

### ZG-3 — Premier Setup Complet VM (Séquence)

```
PROBLÈME :
  Le deploy.yml fait git pull mais le repo
  n'est pas encore cloné sur la VM au premier deploy
  Et le .env n'existe pas encore

SOLUTION : Procédure de premier setup (fait 1 seule fois manuellement)

SÉQUENCE COMPLÈTE PREMIER SETUP :

  Étape A : Sur votre machine locale
    1. Télécharger Wallet depuis Oracle Cloud Console
       Database → votre DB → DB Connection → Download Wallet
    2. Préparer votre clé SSH pour la VM
       ssh-keygen -t ed25519 -f ~/.ssh/pea_quant_vm
       (la clé publique est collée dans Oracle lors de la création VM)

  Étape B : Uploader setup_vm.sh et l'exécuter
    scp -i ~/.ssh/pea_quant_vm deploy/setup_vm.sh \
      ubuntu@VM_IP:/tmp/
    ssh -i ~/.ssh/pea_quant_vm ubuntu@VM_IP
    sudo bash /tmp/setup_vm.sh
    (ce script crée tout : user, dossiers, nginx, systemd)

  Étape C : Uploader le Wallet
    scp -i ~/.ssh/pea_quant_vm Wallet_xxx.zip \
      peaquant@VM_IP:/wallet/
    ssh -i ~/.ssh/pea_quant_vm peaquant@VM_IP
    cd /wallet && unzip Wallet_xxx.zip && rm Wallet_xxx.zip
    chmod 600 /wallet/*

  Étape D : Cloner le repo sur la VM
    ssh -i ~/.ssh/pea_quant_vm peaquant@VM_IP
    cd /app/pea-quant
    git clone https://github.com/votre-user/pea-quant.git .
    /app/pea-quant/venv/bin/pip install -r requirements.txt

  Étape E : Créer le .env sur la VM
    nano /app/pea-quant/.env
    (remplir avec les vraies valeurs Oracle)

  Étape F : Initialiser la DB
    cd /app/pea-quant
    /app/pea-quant/venv/bin/python scripts/bootstrap_db.py

  Étape G : Démarrer les services
    sudo systemctl enable pea-dashboard
    sudo systemctl start pea-dashboard
    sudo systemctl status pea-dashboard

  Étape H : Configurer GitHub Secrets
    VM_HOST = IP publique de la VM
    VM_USER = peaquant
    VM_SSH_KEY = contenu de ~/.ssh/pea_quant_vm (clé PRIVÉE)
    ORACLE_USER = ADMIN
    ORACLE_PASSWORD = xxx
    ORACLE_DSN = mondb_tp
    
    Note : pas de wallet dans GitHub Secrets
           le wallet est sur la VM, déposé manuellement

  Étape I : Tester le deploy automatique
    Faire un commit vide et pusher sur main
    git commit --allow-empty -m "test deploy"
    git push origin main
    Vérifier dans GitHub Actions que le deploy passe
```

---

### ZG-4 — setup_vm.sh : Contenu Complet

```bash
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
echo "2. Cloner le repo dans /app/pea-quant/"
echo "3. Créer /app/pea-quant/.env"
echo "4. python scripts/bootstrap_db.py"
echo "5. systemctl start pea-dashboard"
```

---

### ZG-5 — Pipeline Unique : scheduler/pipeline.py

```
LOGIQUE COMPLÈTE DU PIPELINE

Le script est le seul point d'entrée du cron
Il orchestre les 3 étapes en séquence avec gestion d'erreurs

FLOW DÉTAILLÉ :

  1. VÉRIFICATION JOUR DE BOURSE
     Récupérer la liste des exchanges des tickers actifs
     Pour chaque exchange : is_trading_day(today, exchange)
     Si AUCUN exchange n'est ouvert aujourd'hui → exit(0) proprement
     Si certains exchanges fermés → exclure leurs tickers pour aujourd'hui
     Logger : "Jour férié détecté pour XPAR, tickers XPAR exclus"

  2. FETCH PRICES
     Appeler ingestion.fetch_prices.run(mode='delta')
     Retourne : FetchResult(ok=95, failed=5, rows=100, errors=[...])
     Si failed / total > 0.5 → abort pipeline, log CRITICAL, exit(1)
     Si failed / total > 0.2 → log WARNING, continuer quand même
     Si ok = 0 → abort pipeline, log CRITICAL, exit(1)

  3. CALCULATE INDICATORS
     Appeler indicators.calculator.run(mode='delta')
     Retourne : CalcResult(ok=95, failed=5, errors=[...])
     Si erreur critique (exception non catchée) → abort, log CRITICAL
     Les erreurs par ticker sont des WARNING, pas bloquantes

  4. GENERATE SIGNALS
     Appeler signals.generator.run()
     Retourne : GenResult(ok=95, failed=5, errors=[...])
     Même logique de tolérance

  5. LOG FINAL
     Insérer dans job_logs :
       job_name = 'daily_pipeline'
       status = SUCCESS / PARTIAL / FAILED
       tickers_ok = min des 3 étapes
       error_details = JSON consolidé des 3 étapes
       duration = temps total

GESTION DU FICHIER LOCK :
  Créer /tmp/pea_pipeline.lock au démarrage
  Le supprimer à la fin (finally)
  Si le lock existe au démarrage → un pipeline tourne déjà
  → exit(0) avec log WARNING "Pipeline déjà en cours"
  Évite les doubles exécutions si le cron se chevauche
```

---

### ZG-6 — Algorithme Divergence RSI : Implémentation

```
IMPLÉMENTATION COMPLÈTE

def detect_rsi_divergence(df: pd.DataFrame,
                          lookback: int = 20,
                          pivot_window: int = 3) -> dict:
  """
  df doit avoir les colonnes : close, rsi_14
  lookback : nb de jours à analyser (défaut 20)
  pivot_window : nb de jours de chaque côté pour pivot local (défaut 3)
  
  Retourne : {"bullish": bool, "bearish": bool}
  """

  DÉTECTION PIVOT LOCAL :
    Un point i est un pivot low si :
      close[i] == min(close[i-pivot_window : i+pivot_window+1])
    Un point i est un pivot high si :
      close[i] == max(close[i-pivot_window : i+pivot_window+1])
    
    Note : pivot_window=3 signifie 3 jours de chaque côté
    → minimum 7 jours de données pour 1 pivot
    → minimum 14 jours pour avoir 2 pivots (donc lookback=20 est safe)

  DIVERGENCE HAUSSIÈRE (bullish) :
    Trouver tous les pivot lows dans les lookback derniers jours
    Si moins de 2 pivot lows → bullish = False
    Prendre les 2 plus récents : pivot_recent et pivot_older
    
    Condition :
      close[pivot_recent] < close[pivot_older]  (prix fait lower low)
      ET
      rsi_14[pivot_recent] > rsi_14[pivot_older] (RSI fait higher low)
      ET
      rsi_14[pivot_recent] < 50  (divergence valide seulement en zone basse)
    
    → bullish = True si condition remplie

  DIVERGENCE BAISSIÈRE (bearish) :
    Trouver tous les pivot highs dans les lookback derniers jours
    Si moins de 2 pivot highs → bearish = False
    Prendre les 2 plus récents : pivot_recent et pivot_older
    
    Condition :
      close[pivot_recent] > close[pivot_older]  (prix fait higher high)
      ET
      rsi_14[pivot_recent] < rsi_14[pivot_older] (RSI fait lower high)
      ET
      rsi_14[pivot_recent] > 50  (divergence valide seulement en zone haute)
    
    → bearish = True si condition remplie

  PROTECTION CONTRE FAUX POSITIFS :
    Différence minimum entre les 2 pivots de prix : > 1%
      abs(close[recent] - close[older]) / close[older] > 0.01
    Différence minimum entre les 2 pivots RSI : > 3 points
      abs(rsi[recent] - rsi[older]) > 3
    Si différences trop faibles → pas de divergence (bruit)
```

---

### ZG-7 — Requêtes SQL Dashboard Complètes

```
REQUÊTE SCREENER PRINCIPALE :

  SELECT
    r.ticker_yfinance,
    r.nom,
    r.indice_principal,
    r.segment,
    r.exchange,
    p.close AS prix_actuel,
    p.volume AS volume_jour,
    ROUND((p.close - p_prev.close) / p_prev.close * 100, 2)
      AS variation_pct,
    s.global_score,
    s.trend_score,
    s.momentum_score,
    s.volume_score,
    s.structure_score,
    s.volatility_score,
    s.edge_pullback,
    s.edge_breakout,
    s.edge_squeeze,
    s.edge_divergence,
    s.edge_mean_rev,
    s.edges_count,
    s.signal_direction,
    s.signal_strength,
    s.signal_date
  FROM referentiel_tickers r
  INNER JOIN signals s
    ON r.ticker_yfinance = s.ticker_yfinance
  INNER JOIN prices p
    ON r.ticker_yfinance = p.ticker_yfinance
  LEFT JOIN prices p_prev
    ON r.ticker_yfinance = p_prev.ticker_yfinance
  WHERE
    r.actif = 1
    AND r.is_index = 0
    AND s.signal_date = (
      SELECT MAX(signal_date) FROM signals
    )
    AND p.price_date = (
      SELECT MAX(price_date) FROM prices pp
      WHERE pp.ticker_yfinance = r.ticker_yfinance
    )
    AND p_prev.price_date = (
      SELECT MAX(price_date) FROM prices pp2
      WHERE pp2.ticker_yfinance = r.ticker_yfinance
      AND pp2.price_date < p.price_date
    )
  ORDER BY s.global_score DESC

REQUÊTE FICHE ACTION — PRIX HISTORIQUES :

  SELECT
    price_date,
    open, high, low, close, volume,
    is_valid, validation_flags
  FROM prices
  WHERE ticker_yfinance = :ticker
    AND price_date >= ADD_MONTHS(SYSDATE, -:months)
    AND is_valid = 1
  ORDER BY price_date ASC

  Note : :ticker et :months sont des bind variables
         months = 1, 3, 6, 12, 36 selon sélecteur période

REQUÊTE FICHE ACTION — INDICATEURS HISTORIQUES :

  SELECT
    price_date,
    ema_20, ema_50, ema_200,
    rsi_14, rsi_2,
    macd_line, macd_signal, macd_hist,
    bb_upper, bb_middle, bb_lower,
    volume_sma_20, volume_ratio,
    atr_14, atr_14_pct,
    squeeze_signal,
    high_52w, low_52w,
    pct_from_52w_high
  FROM indicators_daily
  WHERE ticker_yfinance = :ticker
    AND price_date >= ADD_MONTHS(SYSDATE, -:months)
  ORDER BY price_date ASC

REQUÊTE QUALITÉ — STATUT PIPELINE AUJOURD'HUI :

  SELECT
    job_name,
    started_at,
    finished_at,
    duration_seconds,
    status,
    tickers_total,
    tickers_ok,
    tickers_failed,
    rows_inserted,
    error_summary
  FROM job_logs
  WHERE job_name = 'daily_pipeline'
    AND started_at >= TRUNC(SYSDATE)
  ORDER BY started_at DESC
  FETCH FIRST 1 ROWS ONLY

REQUÊTE QUALITÉ — HISTORIQUE 30 JOURS :

  SELECT
    TRUNC(started_at) AS job_date,
    status,
    tickers_ok,
    tickers_total,
    ROUND(tickers_ok / NULLIF(tickers_total, 0) * 100, 1)
      AS pct_ok,
    duration_seconds
  FROM job_logs
  WHERE job_name = 'daily_pipeline'
    AND started_at >= SYSDATE - 30
  ORDER BY started_at ASC

REQUÊTE QUALITÉ — TROUS DE DONNÉES :

  SELECT
    r.ticker_yfinance,
    r.nom,
    r.indice_principal,
    COUNT(p.price_date) AS jours_disponibles,
    MAX(p.price_date) AS derniere_date,
    SYSDATE - MAX(p.price_date) AS jours_retard
  FROM referentiel_tickers r
  LEFT JOIN prices p
    ON r.ticker_yfinance = p.ticker_yfinance
    AND p.price_date >= SYSDATE - 30
  WHERE r.actif = 1
    AND r.is_index = 0
  GROUP BY r.ticker_yfinance, r.nom, r.indice_principal
  HAVING MAX(p.price_date) < SYSDATE - 3
  ORDER BY jours_retard DESC

REQUÊTE QUALITÉ — ESPACE DB :

  SELECT
    ROUND(SUM(bytes) / 1024 / 1024 / 1024, 2) AS gb_used
  FROM dba_segments
  WHERE owner = :oracle_user

  Note : Sur Autonomous DB, utiliser plutôt :
  SELECT
    ROUND(used_space_gb, 2) AS gb_used,
    ROUND(allocated_space_gb, 2) AS gb_allocated
  FROM v$pdbs_storage
  (nécessite les droits appropriés sur Autonomous DB)
  
  Alternative simple sans droits spéciaux :
  SELECT
    segment_type,
    ROUND(SUM(bytes)/1024/1024, 1) AS mb_used
  FROM user_segments
  GROUP BY segment_type
  ORDER BY mb_used DESC
```

---

### ZG-8 — Navigation Dashboard et Cache

```
GESTION CACHE :

  Règle : tout appel DB est décoré @st.cache_data(ttl=3600)
  
  Exception : page Qualité Data → ttl=300 (5 min, plus frais)
  
  Bouton rafraîchir dans sidebar :
    if st.sidebar.button("🔄 Rafraîchir les données"):
      st.cache_data.clear()
      st.rerun()
  
  Ne jamais utiliser st.rerun() automatique en boucle
  Afficher simplement "Données du JJ/MM/YYYY à HH:MM"

NAVIGATION SCREENER → FICHE ACTION :

  Dans screener (01_screener.py) :
    df_display = df avec colonne "Fiche" contenant le ticker
    selection = st.dataframe(
      df_display,
      on_select="rerun",
      selection_mode="single-row"
    )
    if selection.selection.rows:
      idx = selection.selection.rows[0]
      ticker = df.iloc[idx]["ticker_yfinance"]
      st.switch_page("pages/02_fiche_action.py")
      # Stocker le ticker dans session_state avant switch
      st.session_state["selected_ticker"] = ticker
  
  Dans fiche action (02_fiche_action.py) :
    ticker = st.session_state.get("selected_ticker", None)
    if ticker is None:
      # Accès direct à la page sans sélection
      ticker = st.selectbox(
        "Choisir un ticker",
        options=get_all_tickers_from_db()
      )

STRUCTURE app.py :

  st.set_page_config(
    page_title="PEA Quant",
    page_icon="📈",
    layout="wide",
    initial_sidebar_state="expanded"
  )
  
  Sidebar contient :
    Logo/titre
    Date et heure dernière MAJ pipeline
    Indicateur statut : 🟢 OK / 🟡 PARTIAL / 🔴 FAILED
    Bouton Rafraîchir
    Navigation (Streamlit gère auto avec pages/)
  
  Récupérer statut pipeline pour la sidebar :
    @st.cache_data(ttl=300)
    def get_pipeline_status():
      → requête job_logs dernière exécution
      → retourne status + finished_at
```

---

## Plan Complet Final — Version 3.0

---

## Stack Technique

```
┌──────────────────────────────────────────────────────────────────┐
│                         GITHUB                                    │
│                                                                   │
│  Repository PUBLIC                                                │
│  ├── Code source complet                                         │
│  ├── data/tickers/*.json (fichiers statiques maintenus)          │
│  ├── data/market_calendars/*.json                                │
│  └── db/schema/ + db/migrations/                                 │
│                                                                   │
│  GitHub Actions                                                   │
│  ├── ci.yml  → lint + tests (toutes branches)                    │
│  └── deploy.yml → SSH deploy sur VM (main seulement)             │
│                                                                   │
│  GitHub Secrets                                                   │
│  ├── VM_HOST, VM_USER, VM_SSH_KEY                                │
│  ├── ORACLE_USER, ORACLE_PASSWORD                                │
│  ├── ORACLE_DSN, ORACLE_WALLET_PASSWORD                          │
│  └── (wallet lui-même sur VM uniquement, pas dans Secrets)       │
└────────────────────────────┬─────────────────────────────────────┘
                             │ SSH appleboy/ssh-action
                             │ git pull + pip install
                             │ migrate_db + restart service
                             ▼
┌──────────────────────────────────────────────────────────────────┐
│         ORACLE ARM VM — Always Free                               │
│         Ubuntu 22.04 LTS                                         │
│         4 OCPU — 24 GB RAM — 50 GB Boot Volume                  │
│                                                                   │
│  User : peaquant (non-root, droits sudo limités)                 │
│  Répertoires :                                                    │
│    /app/pea-quant/     code + venv                               │
│    /wallet/            Oracle Wallet (déposé manuellement)       │
│    /var/log/pea-quant/ logs rotatifs                             │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Nginx (reverse proxy)                                     │   │
│  │   port 80  → redirect 301 HTTPS                          │   │
│  │   port 443 → proxy_pass 127.0.0.1:8501                  │   │
│  │   WebSocket upgrade (requis Streamlit)                   │   │
│  │   SSL : Let's Encrypt via certbot (renouvellement auto)  │   │
│  └──────────────────────┬─────────────────────────────────-─┘   │
│                          │                                        │
│  ┌───────────────────────▼──────────────────────────────────┐   │
│  │ pea-dashboard.service (systemd)                           │   │
│  │   Streamlit sur 127.0.0.1:8501                           │   │
│  │   EnvironmentFile=/app/pea-quant/.env                    │   │
│  │   Restart=always / RestartSec=10                         │   │
│  │   Logs → /var/log/pea-quant/streamlit.log               │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ Cron (user peaquant)                                      │   │
│  │   19h00 lun-ven → scheduler/pipeline.py                  │   │
│  │     [lock file] → fetch → indicators → signals           │   │
│  │     gestion erreurs + abort si trop de KO               │   │
│  │   10h00 dimanche → scripts/integrity_check.py            │   │
│  │   09h00 trim.    → scripts/ticker_reminder.py            │   │
│  │   03h00 quotidien → certbot renew (SSL)                  │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ /wallet/ (Oracle Wallet — déposé manuellement)           │   │
│  │   cwallet.sso / ewallet.p12                              │   │
│  │   tnsnames.ora / sqlnet.ora                              │   │
│  │   chmod 600 — jamais dans Git                            │   │
│  └──────────────────────────────────────────────────────────┘   │
└───────────────────────────────┬──────────────────────────────────┘
                                │ python-oracledb thin mode
                                │ TCP 1522 + TLS (wallet)
                                │ DSN = mondb_tp
                                ▼
┌──────────────────────────────────────────────────────────────────┐
│        ORACLE AUTONOMOUS DATABASE — Always Free                   │
│        20 GB — Chiffrement automatique — Backup auto             │
│                                                                   │
│  Tables :                                                         │
│    market_calendars       jours fériés par exchange              │
│    referentiel_tickers    univers de tickers + metadata          │
│    prices                 OHLCV validés                          │
│    indicators_daily       ~55 indicateurs par ticker/jour        │
│    signals                scores + edges par ticker/jour         │
│    job_logs               traçabilité pipeline                   │
│    db_migrations          migrations appliquées                  │
│                                                                   │
│  Estimation stockage :                                            │
│    Phase 1 (100 tickers) : ~0.5 GB                              │
│    Phase finale (500 tickers) : ~3-4 GB                         │
│    Croissance : ~0.5 GB/an pour 500 tickers                     │
│    Marge : largement dans les 20 GB                             │
└──────────────────────────────────────────────────────────────────┘
```

---

## Structure Repository Complète

```
pea-quant/
│
├── .github/
│   └── workflows/
│       ├── ci.yml
│       │     # TRIGGER : push toutes branches + PR vers main
│       │     # JOBS :
│       │     #
│       │     # Job 1 : lint
│       │     #   runs-on: ubuntu-latest
│       │     #   steps:
│       │     #     checkout
│       │     #     setup-python 3.11
│       │     #     pip install ruff
│       │     #     ruff check . --select E,F,W,I
│       │     #
│       │     # Job 2 : test
│       │     #   runs-on: ubuntu-latest
│       │     #   steps:
│       │     #     checkout
│       │     #     setup-python 3.11
│       │     #     pip install -r requirements.txt
│       │     #     pytest tests/ -v --tb=short
│       │     #     (pas de connexion Oracle en CI)
│       │     #     (tous les appels DB sont mockés)
│       │     #
│       │     # Job 3 : validate-tickers-json
│       │     #   runs-on: ubuntu-latest
│       │     #   steps:
│       │     #     checkout
│       │     #     setup-python 3.11
│       │     #     python scripts/validate_json_schema.py
│       │     #       (vérifie que chaque ticker JSON
│       │     #        a les champs obligatoires et bons formats)
│       │
│       └── deploy.yml
│             # TRIGGER : push sur main uniquement
│             # CONDITION : ci.yml doit être passé (needs: ci)
│             #
│             # JOBS :
│             # Job : deploy
│             #   runs-on: ubuntu-latest
│             #   needs: [lint, test, validate-tickers-json]
│             #   steps:
│             #     checkout (pour vérif locale éventuelle)
│             #
│             #     Deploy via SSH (appleboy/ssh-action@v1.0.0)
│             #     host    : ${{ secrets.VM_HOST }}
│             #     username: ${{ secrets.VM_USER }}
│             #     key     : ${{ secrets.VM_SSH_KEY }}
│             #     script  :
│             #       set -e
│             #       cd /app/pea-quant
│             #       git fetch origin main
│             #       git reset --hard origin/main
│             #       /app/pea-quant/venv/bin/pip install \
│             #         -r requirements.txt -q
│             #       /app/pea-quant/venv/bin/python \
│             #         scripts/migrate_db.py
│             #       sudo /bin/systemctl restart pea-dashboard
│             #       sleep 15
│             #       sudo /bin/systemctl status pea-dashboard \
│             #         --no-pager | grep "active (running)"
│             #       curl -f \
│             #         http://127.0.0.1:8501/_stcore/health
│             #       echo "Deploy SUCCESS"
│
├── data/
│   ├── tickers/
│   │   │   # FORMAT OBLIGATOIRE pour chaque ticker dans les JSON :
│   │   │   # {
│   │   │   #   "ticker_yfinance": "TTE.PA",  ← suffixe exchange obligatoire
│   │   │   #   "ticker_display": "TTE",
│   │   │   #   "nom": "TotalEnergies SE",
│   │   │   #   "isin": "FR0014000MR3",       ← 12 caractères
│   │   │   #   "pays": "FR",                 ← ISO 3166-1 alpha-2
│   │   │   #   "indice_principal": "CAC40",
│   │   │   #   "indices_appartenance": ["CAC40", "SBF120", "N100"],
│   │   │   #   "segment": "large_caps",      ← large/mid/small
│   │   │   #   "exchange": "XPAR",           ← XPAR/XAMS/XBRU
│   │   │   #   "eligible_pea": true
│   │   │   # }
│   │   │   #
│   │   │   # SUFFIXES YFINANCE PAR EXCHANGE :
│   │   │   #   XPAR (Paris)     → .PA  ex: TTE.PA, AI.PA, BNP.PA
│   │   │   #   XAMS (Amsterdam) → .AS  ex: ASML.AS, HEIA.AS, PHIA.AS
│   │   │   #   XBRU (Bruxelles) → .BR  ex: ABI.BR, UCB.BR, SOLB.BR
│   │   │   #
│   │   ├── cac40.json              # 40 tickers — Niveau 1
│   │   ├── cac_next20.json         # 20 tickers — Niveau 1
│   │   ├── aex.json                # 25 tickers — Niveau 1
│   │   ├── bel20.json              # 20 tickers — Niveau 1
│   │   ├── sbf120.json             # ~80 tickers additionnels — Niveau 2
│   │   ├── cac_mid60.json          # ~60 tickers — Niveau 2
│   │   ├── amx.json                # ~25 tickers — Niveau 2
│   │   ├── bel_mid.json            # ~20 tickers — Niveau 2
│   │   ├── cac_small.json          # ~150 tickers — Niveau 3
│   │   └── pan_european.json       # N100, Next150 — Niveau 3
│   │
│   └── market_calendars/
│       │   # FORMAT :
│       │   # {
│       │   #   "exchange": "XPAR",
│       │   #   "timezone": "Europe/Paris",
│       │   #   "open_time": "09:00",
│       │   #   "close_time": "17:30",
│       │   #   "holidays": {
│       │   #     "2024": [
│       │   #       "2024-01-01",
│       │   #       "2024-04-01",
│       │   #       ...
│       │   #     ],
│       │   #     "2025": [...]
│       │   #   }
│       │   # }
│       ├── xpar.json               # Jours fériés Euronext Paris
│       ├── xams.json               # Jours fériés Euronext Amsterdam
│       └── xbru.json               # Jours fériés Euronext Bruxelles
│
├── db/
│   ├── schema/
│   │   │   # Scripts SQL exécutés dans l'ordre numérique
│   │   │   # lors du bootstrap_db.py initial
│   │   │   # Tous idempotents : CREATE TABLE IF NOT EXISTS équivalent
│   │   │   # Oracle utilise : BEGIN EXECUTE IMMEDIATE '...'; EXCEPTION
│   │   │   #                  WHEN OTHERS THEN NULL; END;
│   │   ├── 001_market_calendars.sql
│   │   ├── 002_referentiel_tickers.sql
│   │   ├── 003_prices.sql
│   │   ├── 004_indicators_daily.sql
│   │   ├── 005_signals.sql
│   │   ├── 006_job_logs.sql
│   │   └── 007_db_migrations.sql
│   │
│   └── migrations/
│       # Chaque fichier = une migration numérotée
│       # Format nom : 008_description_courte.sql
│       # Script idempotent (ne refait pas si déjà fait)
│       # Tracé dans table db_migrations
│       # Exécuté automatiquement par migrate_db.py au deploy
│       # Exemples futurs :
│       #   008_add_rsi_7_column.sql
│       #   009_add_edge_squeeze_strength.sql
│
├── core/
│   ├── __init__.py
│   │
│   ├── config.py
│   │     # Charge os.environ + python-dotenv
│   │     # Toutes les constantes du projet ici
│   │     # Jamais de valeurs en dur dans les autres fichiers
│   │     #
│   │     # ORACLE
│   │     #   ORACLE_USER, PASSWORD, DSN
│   │     #   ORACLE_WALLET_PATH, ORACLE_WALLET_PASSWORD
│   │     #
│   │     # YFINANCE
│   │     #   BATCH_SIZE = 50
│   │     #   SLEEP_BETWEEN_BATCHES = 5  (secondes)
│   │     #   TIMEOUT = 30
│   │     #   MAX_RETRIES = 3
│   │     #   HISTORY_YEARS = 5
│   │     #   MAX_FAIL_RATIO = 0.5  (abort si > 50% KO)
│   │     #
│   │     # INDICATEURS (fenêtres)
│   │     #   GLOBAL_LOOKBACK = 400
│   │     #   INDICATOR_MIN_PERIODS = {dict complet ZG-3}
│   │     #
│   │     # SCORING
│   │     #   MIN_LIQUIDITY_EUR = 500_000
│   │     #   MIN_DATA_DAYS = 60
│   │     #   SCORE_WEIGHTS = {
│   │     #     "trend": 0.30, "momentum": 0.25,
│   │     #     "volume": 0.20, "structure": 0.15,
│   │     #     "volatility": 0.10
│   │     #   }
│   │     #
│   │     # PIPELINE
│   │     #   LOCK_FILE = "/tmp/pea_pipeline.lock"
│   │     #   PIPELINE_ABORT_FAIL_RATIO = 0.5
│   │     #
│   │     # PATHS
│   │     #   DATA_DIR = Path(__file__).parent.parent / "data"
│   │     #   TICKERS_DIR = DATA_DIR / "tickers"
│   │     #   CALENDARS_DIR = DATA_DIR / "market_calendars"
│   │
│   ├── db.py
│   │     # Connexion Oracle en mode THIN (python-oracledb)
│   │     # PAS d'init_oracle_client() — thin mode ne le nécessite pas
│   │     #
│   │     # class OracleDB:
│   │     #
│   │     #   __instance = None (singleton)
│   │     #
│   │     #   def connect():
│   │     #     oracledb.connect(
│   │     #       user=config.ORACLE_USER,
│   │     #       password=config.ORACLE_PASSWORD,
│   │     #       dsn=config.ORACLE_DSN,
│   │     #       wallet_location=config.ORACLE_WALLET_PATH,
│   │     #       wallet_password=config.ORACLE_WALLET_PASSWORD
│   │     #     )
│   │     #
│   │     #   Context manager :
│   │     #     __enter__ → self.connect() → return self
│   │     #     __exit__  → self.conn.close()
│   │     #
│   │     #   execute(sql, params=None)
│   │     #     → cursor.execute(sql, params or {})
│   │     #     → conn.commit()
│   │     #     → retry 3x si ORA-03113 (connexion perdue)
│   │     #
│   │     #   execute_many(sql, list_of_params)
│   │     #     → cursor.executemany(sql, list_of_params)
│   │     #     → conn.commit()
│   │     #
│   │     #   fetch_one(sql, params) → dict ou None
│   │     #   fetch_all(sql, params) → list[dict]
│   │     #   fetch_df(sql, params)  → pd.DataFrame
│   │     #     (via pd.DataFrame(cursor.fetchall(),
│   │     #             columns=[d[0] for d in cursor.description]))
│   │     #
│   │     #   upsert(table, data_dict, conflict_keys)
│   │     #     Construit un MERGE Oracle :
│   │     #     MERGE INTO table t
│   │     #     USING (SELECT :val1 col1 FROM dual) s
│   │     #     ON (t.conflict_key = s.conflict_key)
│   │     #     WHEN MATCHED THEN UPDATE SET ...
│   │     #     WHEN NOT MATCHED THEN INSERT ...
│   │
│   ├── logger.py
│   │     # Utilise loguru pour la partie fichier
│   │     # logger.add("/var/log/pea-quant/{time}.log",
│   │     #            rotation="1 day", retention="30 days",
│   │     #            level="INFO")
│   │     #
│   │     # class JobLogger:
│   │     #   job_id: int
│   │     #   job_name: str
│   │     #   started_at: datetime
│   │     #   stats: dict
│   │     #
│   │     #   start(job_name, mode) → job_id
│   │     #     INSERT INTO job_logs (job_name, mode, started_at, status)
│   │     #     VALUES (..., 'RUNNING')
│   │     #     Retourne l'id inséré
│   │     #
│   │     #   info(msg, ticker=None)
│   │     #   warning(msg, ticker=None)
│   │     #   error(msg, ticker=None)
│   │     #     Log dans fichier + accumule dans self.stats
│   │     #
│   │     #   finish(status, stats)
│   │     #     UPDATE job_logs SET
│   │     #       finished_at=NOW(),
│   │     #       duration_seconds=...,
│   │     #       status=status,
│   │     #       tickers_total=stats.total,
│   │     #       tickers_ok=stats.ok,
│   │     #       tickers_failed=stats.failed,
│   │     #       rows_inserted=stats.inserted,
│   │     #       error_details=JSON(stats.errors)
│   │     #     WHERE id=self.job_id
│   │
│   └── calendar.py
│         # Charge les JSON depuis data/market_calendars/
│         # Cache en mémoire (dict par exchange)
│         #
│         # is_trading_day(date: date, exchange: str) → bool
│         #   False si samedi ou dimanche
│         #   False si dans la liste holidays de l'exchange
│         #   True sinon
│         #
│         # get_last_trading_day(exchange: str) → date
│         #   Commence à today et recule jusqu'à trouver
│         #   un jour de bourse (max 7 jours de recherche)
│         #
│         # get_trading_days_between(start, end, exchange) → list[date]
│         #   Tous les jours de bourse entre start et end
│         #
│         # get_missing_trading_days(ticker, exchange, db) → list[date]
│         #   Récupère les dates existantes depuis prices en DB
│         #   Calcule les dates attendues via get_trading_days_between
│         #   Retourne la différence (jours manquants)
│
├── ingestion/
│   ├── __init__.py
│   │
│   ├── validate_tickers.py
│   │     # Input  : tous les fichiers data/tickers/*.json
│   │     # Output : data/tickers_validated.json (gitignored)
│   │     #          + rapport console
│   │     #
│   │     # CHARGEMENT :
│   │     #   Lire tous les *.json dans data/tickers/
│   │     #   Dédupliquer sur ticker_yfinance
│   │     #   (un ticker peut apparaître dans plusieurs indices)
│   │     #
│   │     # VALIDATION SCHEMA JSON :
│   │     #   Champs obligatoires : ticker_yfinance, nom, isin,
│   │     #                         pays, indice_principal, exchange
│   │     #   Format ISIN : 2 lettres + 10 alphanum (regex)
│   │     #   Format pays : 2 lettres majuscules
│   │     #   Exchange dans : XPAR, XAMS, XBRU
│   │     #   Suffixe yfinance cohérent avec exchange :
│   │     #     XPAR → se termine par .PA
│   │     #     XAMS → se termine par .AS
│   │     #     XBRU → se termine par .BR
│   │     #
│   │     # VALIDATION YFINANCE :
│   │     #   Batch 50 tickers max
│   │     #   sleep 5s entre batches
│   │     #   Pour chaque ticker :
│   │     #     yf.download(ticker, period='5d', progress=False)
│   │     #     Si DataFrame vide → valid=False, raison="no_data"
│   │     #     Si colonnes OHLCV manquantes → valid=False
│   │     #     Si tout OK → valid=True
│   │     #
│   │     # OUTPUT tickers_validated.json :
│   │     #   Liste complète avec champ "valid": true/false
│   │     #   et "validation_error": "raison si false"
│   │     #
│   │     # RAPPORT FINAL :
│   │     #   Total tickers : X
│   │     #   Valides : Y
│   │     #   Invalides : Z (liste avec raisons)
│   │
│   ├── validate_ohlcv.py
│   │     # Input  : pd.DataFrame yfinance (colonnes OHLCV standard)
│   │     # Output : même DataFrame + colonnes is_valid, validation_flags,
│   │     #          validation_notes
│   │     #
│   │     # RÈGLES (appliquées ligne par ligne) :
│   │     #
│   │     # is_valid = False (bloquant) :
│   │     #   R01 : high < low
│   │     #   R02 : high < open
│   │     #   R03 : high < close
│   │     #   R04 : low > open
│   │     #   R05 : low > close
│   │     #   R06 : volume < 0
│   │     #   R07 : open <= 0 OU high <= 0 OU low <= 0 OU close <= 0
│   │     #   R13 : close == 0
│   │     #   R14 : high == low == open == close (zombie price)
│   │     #   R15 : |variation_pct| > 200% en 1 jour
│   │     #         variation_pct = (close - prev_close) / prev_close * 100
│   │     #
│   │     # WARNING (is_valid reste True, flag ajouté) :
│   │     #   R08 : |variation_pct| > 25% → flag "R08"
│   │     #   R09 : |variation_pct| > 50% → flag "R09"
│   │     #   R10 : volume == 0 → flag "R10"
│   │     #   R11 : 5 jours consécutifs même close → flag "R11"
│   │     #   R12 : |close_adj - close| / close > 10% → flag "R12"
│   │     #
│   │     # validation_flags : string codes séparés virgule
│   │     #   ex : "" si aucun flag
│   │     #        "R08" si variation suspecte
│   │     #        "R08,R10" si variation + volume 0
│   │     #
│   │     # GESTION prev_close :
│   │     #   Les règles R08/R09/R15 nécessitent la ligne précédente
│   │     #   Si première ligne du DataFrame → ces règles ignorées
│   │
│   └── fetch_prices.py
│         # Classe FetchResult(dataclass) :
│         #   total: int, ok: int, failed: int
│         #   rows_inserted: int, rows_updated: int
│         #   errors: list[dict]  # {ticker, error, timestamp}
│         #
│         # def run(mode='delta') → FetchResult :
│         #
│         # MODE DELTA :
│         #   Récupérer depuis DB la last_price_date par ticker actif
│         #     SELECT ticker_yfinance, last_price_date
│         #     FROM referentiel_tickers
│         #     WHERE actif=1 AND is_index=0
│         #   Déterminer start_date = last_price_date + 1 jour
│         #   Déterminer end_date = aujourd'hui
│         #   Si start_date > end_date → rien à fetcher pour ce ticker
│         #   Vérifier que end_date est jour de bourse pour cet exchange
│         #
│         # MODE BOOTSTRAP :
│         #   start_date = today - 5 ans
│         #   end_date = today
│         #   Pour tous les tickers actifs
│         #
│         # FETCH PAR BATCH :
│         #   Grouper les tickers par batch de BATCH_SIZE
│         #   Pour chaque batch :
│         #     yf.download(
│         #       tickers=batch,
│         #       start=start_date,
│         #       end=end_date,
│         #       auto_adjust=True,
│         #       progress=False,
│         #       group_by='ticker',
│         #       threads=False
│         #     )
│         #     Note : threads=False pour éviter les race conditions
│         #            auto_adjust=True → close_adjusted = close
│         #            et les splits/dividendes sont déjà dans le close
│         #     sleep(SLEEP_BETWEEN_BATCHES)
│         #
│         # POUR CHAQUE TICKER dans le résultat :
│         #   1. Extraire le sous-DataFrame du ticker
│         #   2. Si DataFrame vide → log WARNING, ajouter à errors
│         #   3. Renommer colonnes : Open→open, High→high, etc.
│         #   4. Ajouter colonne close_adjusted = close (auto_adjust)
│         #   5. validate_ohlcv(df) → df avec is_valid + flags
│         #   6. Upsert en DB (conflict sur ticker+date)
│         #      UPDATE referentiel_tickers SET last_price_date=max(date)
│         #   7. Incrémenter stats ok/failed/rows
│         #
│         # RETRY :
│         #   Sur timeout ou erreur réseau : retry 3x
│         #   Backoff : 2s, 4s, 8s (exponentiel)
│         #   Si 3 échecs → log ERROR pour ce ticker, continuer
│         #
│         # INDICES DE RÉFÉRENCE (pour beta) :
│         #   Fetcher aussi ^FCHI, ^AEX, ^BFX
│         #   Ces tickers ont is_index=1 dans referentiel_tickers
│         #   Même logique fetch mais pas de validation PEA
│
├── indicators/
│   ├── __init__.py
│   │
│   ├── _base.py
│   │     # Constante INDICATOR_WINDOWS importée depuis config
│   │     # (dict complet défini dans ZG-3)
│   │     #
│   │     # def check_min_periods(df, indicator_name) → bool :
│   │     #   min_req = INDICATOR_WINDOWS[indicator_name]["min_periods"]
│   │     #   return len(df) >= min_req
│   │     #
│   │     # def get_lookback(indicator_name) → int :
│   │     #   return INDICATOR_WINDOWS[indicator_name]["lookback"]
│   │     #
│   │     # RÈGLE FONDAMENTALE :
│   │     #   Si check_min_periods retourne False
│   │     #   → retourner une Series de NaN de la bonne longueur
│   │     #   → PAS d'exception levée
│   │     #   → Les NaN sont stockés en DB comme NULL
│   │     #   → Le scoring ignore les NULL (filtre data_ok)
│   │
│   ├── trend.py
│   │     # Toutes les fonctions prennent df en entrée
│   │     # et retournent une Series ou DataFrame pandas
│   │     #
│   │     # calc_ema(df, period) → Series
│   │     #   pandas_ta : df.ta.ema(length=period)
│   │     #   min_periods : period * 2
│   │     #
│   │     # calc_sma(df, period) → Series
│   │     #   pandas_ta : df.ta.sma(length=period)
│   │     #   min_periods : period
│   │     #
│   │     # calc_adx(df, period=14) → DataFrame
│   │     #   pandas_ta : df.ta.adx(length=period)
│   │     #   Colonnes retournées : ADX_14, DMP_14, DMN_14
│   │     #   min_periods : period * 2
│   │     #
│   │     # calc_ichimoku(df) → DataFrame
│   │     #   pandas_ta : df.ta.ichimoku()
│   │     #   Colonnes : ISA_9 (senkou A), ISB_26 (senkou B),
│   │     #              ITS_9 (tenkan), IKS_26 (kijun),
│   │     #              ICS_26 (chikou)
│   │     #   min_periods : 78
│   │     #   Note : senkou A et B sont projetées dans le futur
│   │     #          prendre la valeur courante (index = today)
│   │
│   ├── momentum.py
│   │     # calc_rsi(df, period) → Series
│   │     #   Pour periods : 2, 7, 14
│   │     #   pandas_ta : df.ta.rsi(length=period)
│   │     #   Résultat toujours entre 0 et 100
│   │     #
│   │     # calc_macd(df, fast=12, slow=26, signal=9) → DataFrame
│   │     #   pandas_ta : df.ta.macd(fast=12, slow=26, signal=9)
│   │     #   Colonnes : MACD_12_26_9, MACDs_12_26_9, MACDh_12_26_9
│   │     #   min_periods : slow + signal = 35
│   │     #
│   │     # calc_roc(df, period) → Series
│   │     #   Pour periods : 5, 10, 20
│   │     #   pandas_ta : df.ta.roc(length=period)
│   │     #   ROC = (close/close[n] - 1) * 100
│   │     #
│   │     # calc_stoch(df, k=14, d=3, smooth=3) → DataFrame
│   │     #   pandas_ta : df.ta.stoch(k=14, d=3, smooth_k=3)
│   │     #   Colonnes : STOCHk_14_3_3, STOCHd_14_3_3
│   │     #   Résultat toujours entre 0 et 100
│   │     #
│   │     # calc_williams_r(df, period=14) → Series
│   │     #   pandas_ta : df.ta.willr(length=14)
│   │     #   Résultat toujours entre -100 et 0
│   │     #
│   │     # detect_rsi_divergence(df, lookback=20) → dict
│   │     #   Algorithme complet défini dans ZG-6
│   │     #   Input df doit avoir : close, rsi_14
│   │     #   Retourne : {"bullish": bool, "bearish": bool}
│   │
│   ├── volatility.py
│   │     # calc_atr(df, period=14) → DataFrame
│   │     #   pandas_ta : df.ta.atr(length=14)
│   │     #   → atr_14 (valeur absolue)
│   │     #   → atr_14_pct = atr_14 / close * 100
│   │     #
│   │     # calc_bollinger(df, period=20, std=2) → DataFrame
│   │     #   pandas_ta : df.ta.bbands(length=20, std=2)
│   │     #   Colonnes pandas_ta :
│   │     #     BBL_20_2.0 (lower)
│   │     #     BBM_20_2.0 (middle)
│   │     #     BBU_20_2.0 (upper)
│   │     #     BBB_20_2.0 (bandwidth)
│   │     #     BBP_20_2.0 (percent B)
│   │     #
│   │     # calc_keltner(df, period=20, atr_mult=1.5) → DataFrame
│   │     #   pandas_ta : df.ta.kc(length=20, scalar=1.5)
│   │     #   Colonnes : KCLe_20_1.5 (lower), KCMe_20_1.5 (middle),
│   │     #              KCUe_20_1.5 (upper)
│   │     #
│   │     # calc_squeeze(df) → DataFrame
│   │     #   Squeeze = BB inside KC
│   │     #   squeeze_signal = (bb_upper < kc_upper) AND
│   │     #                    (bb_lower > kc_lower)
│   │     #   pandas_ta : df.ta.squeeze(detailed=True)
│   │     #   → squeeze_signal (bool)
│   │     #   → squeeze_hist (momentum oscillateur)
│   │     #
│   │     # calc_historical_volatility(df, period=30) → Series
│   │     #   log_returns = np.log(close / close.shift(1))
│   │     #   vol = log_returns.rolling(period).std() * np.sqrt(252) * 100
│   │
│   ├── volume.py
│   │     # calc_obv(df) → DataFrame
│   │     #   pandas_ta : df.ta.obv()
│   │     #   + obv_trend_5d : OBV aujourd'hui > OBV il y a 5j → 1
│   │     #   + obv_trend_10d : OBV aujourd'hui > OBV il y a 10j → 1
│   │     #
│   │     # calc_volume_stats(df) → DataFrame
│   │     #   volume_sma_20 = df.ta.sma(close=volume, length=20)
│   │     #   volume_ratio = volume / volume_sma_20
│   │     #   liquidity_eur = close * volume
│   │     #   liquidity_eur_avg20 = liquidity_eur.rolling(20).mean()
│   │     #
│   │     # calc_mfi(df, period=14) → Series
│   │     #   pandas_ta : df.ta.mfi(length=14)
│   │     #   Résultat entre 0 et 100
│   │     #
│   │     # calc_vwap(df, period=20) → Series
│   │     #   Rolling VWAP (pas intraday, version rolling daily)
│   │     #   typical_price = (high + low + close) / 3
│   │     #   vwap = (typical_price * volume).rolling(period).sum()
│   │     #          / volume.rolling(period).sum()
│   │
│   ├── structure.py
│   │     # calc_pivots(df) → DataFrame
│   │     #   Calculé sur J-1 (previous day OHLC)
│   │     #   pp = (prev_high + prev_low + prev_close) / 3
│   │     #   r1 = 2*pp - prev_low
│   │     #   r2 = pp + (prev_high - prev_low)
│   │     #   s1 = 2*pp - prev_high
│   │     #   s2 = pp - (prev_high - prev_low)
│   │     #   Utiliser df.shift(1) pour prev_high/low/close
│   │     #
│   │     # calc_price_levels(df) → DataFrame
│   │     #   high_52w = df['high'].rolling(252).max()
│   │     #   low_52w  = df['low'].rolling(252).min()
│   │     #   high_20d = df['high'].rolling(20).max()
│   │     #   low_20d  = df['low'].rolling(20).min()
│   │     #   pct_from_52w_high = (close - high_52w) / high_52w * 100
│   │     #   pct_from_52w_low  = (close - low_52w)  / low_52w  * 100
│   │     #   min_periods=252 pour high_52w/low_52w → NaN si < 1 an
│   │     #
│   │     # calc_gaps(df) → DataFrame
│   │     #   gap_pct = (open - prev_close) / prev_close * 100
│   │     #   gap_type :
│   │     #     'none' si |gap_pct| < 0.5
│   │     #     'up'   si gap_pct >= 0.5
│   │     #     'down' si gap_pct <= -0.5
│   │
│   ├── quality.py
│   │     # calc_beta(df_ticker, df_index, period=60) → Series
│   │     #   df_ticker : DataFrame prix du ticker
│   │     #   df_index  : DataFrame prix de l'indice de référence
│   │     #               (chargé depuis DB, is_index=1)
│   │     #   Indice par exchange :
│   │     #     XPAR → ^FCHI
│   │     #     XAMS → ^AEX
│   │     #     XBRU → ^BFX
│   │     #   returns_ticker = close_ticker.pct_change()
│   │     #   returns_index  = close_index.pct_change()
│   │     #   Aligner les deux Series sur les mêmes dates
│   │     #   beta = rolling covariance(60j) / rolling variance_index(60j)
│   │     #   min_periods : 60
│   │
│   └── calculator.py
│         # Orchestrateur de tous les indicateurs
│         #
│         # class CalcResult(dataclass) :
│         #   total, ok, failed: int
│         #   errors: list[dict]
│         #
│         # def run(mode='delta') → CalcResult :
│         #
│         # RÉCUPÉRATION DONNÉES :
│         #   Pour chaque ticker actif (is_index=0) :
│         #     Charger GLOBAL_LOOKBACK=400 jours de prices depuis DB
│         #     SELECT * FROM prices
│         #     WHERE ticker_yfinance=:t
│         #       AND is_valid=1
│         #       AND price_date >= SYSDATE - 400
│         #     ORDER BY price_date ASC
│         #     → Si < 10 lignes → log WARNING, skip
│         #
│         # RÉCUPÉRATION INDICES (pour beta) :
│         #   Charger ^FCHI, ^AEX, ^BFX depuis DB (400 jours)
│         #   Une seule fois avant la boucle principale
│         #
│         # CALCUL PAR TICKER :
│         #   Ordre des calculs (certains dépendent d'autres) :
│         #   1. trend.calc_ema, calc_sma, calc_adx, calc_ichimoku
│         #   2. volatility.calc_atr     ← ATR avant Keltner
│         #   3. volatility.calc_bollinger
│         #   4. volatility.calc_keltner ← nécessite ATR
│         #   5. volatility.calc_squeeze ← nécessite BB et KC
│         #   6. volatility.calc_historical_volatility
│         #   7. momentum.calc_rsi (2, 7, 14)
│         #   8. momentum.calc_macd
│         #   9. momentum.calc_roc (5, 10, 20)
│         #   10. momentum.calc_stoch
│         #   11. momentum.calc_williams_r
│         #   12. momentum.detect_rsi_divergence ← nécessite rsi_14
│         #   13. volume.calc_obv
│         #   14. volume.calc_volume_stats
│         #   15. volume.calc_mfi
│         #   16. volume.calc_vwap
│         #   17. structure.calc_pivots
│         #   18. structure.calc_price_levels
│         #   19. structure.calc_gaps
│         #   20. quality.calc_beta (avec df_index correspondant)
│         #
│         # MODE DELTA :
│         #   Calculer tout sur les 400 jours
│         #   Mais n'insérer en DB QUE la dernière ligne (today)
│         #   MERGE INTO indicators_daily
│         #   ON (ticker_yfinance=:t AND price_date=:d)
│         #
│         # MODE BOOTSTRAP :
│         #   Calculer tout et insérer toutes les lignes
│         #   Batch inserts de 1000 lignes pour performance
│
├── signals/
│   ├── __init__.py
│   │
│   ├── scoring.py
│   │     # Logique complète définie dans V2 + ZG compléments
│   │     # Fonctions :
│   │     #
│   │     # calc_trend_score(row) → float (0-100)
│   │     #   row = dict des indicateurs d'un ticker pour un jour
│   │     #   Critères et points définis dans V2
│   │     #
│   │     # calc_momentum_score(row) → float (0-100)
│   │     # calc_volume_score(row) → float (0-100)
│   │     # calc_structure_score(row) → float (0-100)
│   │     # calc_volatility_score(row) → float (0-100)
│   │     #
│   │     # calc_global_score(scores_dict) → float (0-100)
│   │     #   weights = config.SCORE_WEIGHTS
│   │     #   = trend*0.30 + momentum*0.25 + volume*0.20
│   │     #     + structure*0.15 + volatility*0.10
│   │     #
│   │     # FILTRES ÉLIMINATOIRES (avant tout calcul) :
│   │     #   check_liquidity(row) → bool
│   │     #     row["liquidity_eur_avg20"] >= MIN_LIQUIDITY_EUR
│   │     #   check_data_quality(row) → bool
│   │     #     Pas de NULL sur les indicateurs clés
│   │     #     (rsi_14, ema_20, atr_14, volume_ratio)
│   │     #   Si filtre KO → score = 0, flag dans score_details
│   │
│   ├── edges.py
│   │     # Logique complète des 5 edges définie dans V2
│   │     # Fonctions :
│   │     #
│   │     # detect_edge_pullback(row, scores) → tuple(bool, str)
│   │     #   Retourne (True/False, "STRONG"/"MEDIUM"/"WEAK")
│   │     #
│   │     # detect_edge_breakout(row, scores) → tuple(bool, str)
│   │     # detect_edge_squeeze(row, scores) → tuple(bool, str)
│   │     # detect_edge_divergence(row, scores) → tuple(bool, str)
│   │     # detect_edge_mean_reversion(row, scores) → tuple(bool, str)
│   │     #
│   │     # detect_all_edges(row, scores) → dict
│   │     #   Appelle les 5 fonctions
│   │     #   Retourne :
│   │     #   {
│   │     #     "pullback":     {"active": bool, "strength": str},
│   │     #     "breakout":     {"active": bool, "strength": str},
│   │     #     "squeeze":      {"active": bool, "strength": str},
│   │     #     "divergence":   {"active": bool, "strength": str},
│   │     #     "mean_rev":     {"active": bool, "strength": str},
│   │     #     "count": int,   # nb d'edges actifs simultanément
│   │     #   }
│   │     #
│   │     # determine_direction(edges, scores) → str
│   │     #   "LONG"    si au moins 1 edge LONG actif
│   │     #             et trend_score > 40
│   │     #   "NEUTRAL" si squeeze seul actif
│   │     #   "NEUTRAL" si aucun edge actif
│   │     #
│   │     # determine_strength(edges) → str
│   │     #   "STRONG" si edges_count >= 2 OU un edge STRONG
│   │     #   "MEDIUM" si edges_count == 1 et MEDIUM
│   │     #   "WEAK"   si edges_count == 1 et WEAK
│   │     #   "NONE"   si edges_count == 0
│   │
│   └── generator.py
│         # class GenResult(dataclass) :
│         #   total, ok, failed: int
│         #   errors: list[dict]
│         #
│         # def run() → GenResult :
│         #
│         # RÉCUPÉRATION :
│         #   today = date.today()
│         #   Récupérer tous les tickers actifs (is_index=0)
│         #   Pour chaque ticker :
│         #     Récupérer derniers indicateurs depuis indicators_daily
│         #     WHERE ticker=t AND price_date = (SELECT MAX...)
│         #     → dict "row"
│         #
│         # TRAITEMENT PAR TICKER :
│         #   1. check_liquidity + check_data_quality
│         #   2. calc_trend_score(row)     → trend_score
│         #   3. calc_momentum_score(row)  → momentum_score
│         #   4. calc_volume_score(row)    → volume_score
│         #   5. calc_structure_score(row) → structure_score
│         #   6. calc_volatility_score(row)→ volatility_score
│         #   7. scores = {trend, momentum, volume, structure, volatility}
│         #   8. calc_global_score(scores) → global_score
│         #   9. detect_all_edges(row, scores) → edges
│         #   10. determine_direction(edges, scores)
│         #   11. determine_strength(edges)
│         #   12. Construire score_details JSON :
│         #       {
│         #         "trend": {"score": 75, "details": {
│         #           "prix_vs_ema200": 30,
│         #           "alignement_emas": 25,
│         #           "adx": 15,
│         #           "ichimoku": 5
│         #         }},
│         #         "momentum": {...},
│         #         "volume": {...},
│         #         "structure": {...},
│         #         "volatility": {...},
│         #         "edges": {edges dict complet},
│         #         "filters": {
│         #           "liquidity_ok": bool,
│         #           "data_ok": bool
│         #         }
│         #       }
│         #   13. MERGE INTO signals
│         #       ON (ticker=t AND signal_date=today)
│
├── dashboard/
│   ├── app.py
│   │     # st.set_page_config(
│   │     #   page_title="PEA Quant",
│   │     #   page_icon="📈",
│   │     #   layout="wide",
│   │     #   initial_sidebar_state="expanded"
│   │     # )
│   │     #
│   │     # SIDEBAR :
│   │     #   Titre + version
│   │     #   @st.cache_data(ttl=300)
│   │     #   get_pipeline_status() → requête job_logs
│   │     #   Afficher : "🟢 Pipeline OK — 20h05" ou "🔴 FAILED"
│   │     #   Afficher : "Données du DD/MM/YYYY"
│   │     #   Bouton "🔄 Rafraîchir" → st.cache_data.clear() + rerun
│   │     #
│   │     # Navigation gérée automatiquement par Streamlit
│   │     # (fichiers dans pages/ détectés automatiquement)
│   │
│   ├── pages/
│   │   ├── 01_screener.py
│   │   │     # CACHE : @st.cache_data(ttl=3600)
│   │   │     #
│   │   │     # CHARGEMENT :
│   │   │     #   Requête SQL complète définie dans ZG-7
│   │   │     #   → DataFrame "df"
│   │   │     #
│   │   │     # FILTRES SIDEBAR :
│   │   │     #   Utiliser components/filters.py
│   │   │     #   Appliquer filtres sur df en mémoire
│   │   │     #   (pas de requête SQL par filtre = plus rapide)
│   │   │     #
│   │   │     # RÉSUMÉ MÉTRIQUES (st.columns x4) :
│   │   │     #   Nb actions affichées / total
│   │   │     #   Nb signaux STRONG aujourd'hui
│   │   │     #   Nb breakouts actifs
│   │   │     #   Nb pullbacks actifs
│   │   │     #
│   │   │     # TABLEAU :
│   │   │     #   st.dataframe(
│   │   │     #     df_filtered,
│   │   │     #     on_select="rerun",
│   │   │     #     selection_mode="single-row",
│   │   │     #     column_config={
│   │   │     #       "global_score": st.column_config.ProgressColumn(
│   │   │     #         min_value=0, max_value=100
│   │   │     #       ),
│   │   │     #       "variation_pct": st.column_config.NumberColumn(
│   │   │     #         format="%.2f%%"
│   │   │     #       ),
│   │   │     #       ...
│   │   │     #     }
│   │   │     #   )
│   │   │     #
│   │   │     # NAVIGATION VERS FICHE :
│   │   │     #   if selection.selection.rows:
│   │   │     #     idx = selection.selection.rows[0]
│   │   │     #     ticker = df_filtered.iloc[idx]["ticker_yfinance"]
│   │   │     #     st.session_state["selected_ticker"] = ticker
│   │   │     #     st.switch_page("pages/02_fiche_action.py")
│   │   │     #
│   │   │     # EXPORT CSV :
│   │   │     #   st.download_button(
│   │   │     #     "📥 Export CSV",
│   │   │     #     df_filtered.to_csv(index=False),
│   │   │     #     "screener.csv"
│   │   │     #   )
│   │   │
│   │   ├── 02_fiche_action.py
│   │   │     # RÉCUPÉRATION TICKER :
│   │   │     #   ticker = st.session_state.get("selected_ticker")
│   │   │     #   Si None → selectbox pour choisir manuellement
│   │   │     #
│   │   │     # CACHE : @st.cache_data(ttl=3600) sur chaque requête
│   │   │     #
│   │   │     # HEADER (st.columns) :
│   │   │     #   Nom | Ticker | ISIN | Indice | Segment
│   │   │     #   Prix | Variation | Volume
│   │   │     #
│   │   │     # SCORE CARDS (st.columns x5) :
│   │   │     #   components/charts.make_score_gauge(score, label)
│   │   │     #   [Trend:75] [Momentum:60] [Volume:45]
│   │   │     #   [Structure:80] [Volatility:55]
│   │   │     #   Score Global bien visible (st.metric)
│   │   │     #
│   │   │     # EDGES DÉTECTÉS :
│   │   │     #   Lire score_details JSON depuis signals
│   │   │     #   Pour chaque edge actif : badge vert + description
│   │   │     #   Descriptions textuelles prédéfinies par edge
│   │   │     #
│   │   │     # SÉLECTEUR PÉRIODE :
│   │   │     #   st.radio("Période", ["1M", "3M", "6M", "1AN", "3ANS"])
│   │   │     #   → months = [1, 3, 6, 12, 36][index]
│   │   │     #
│   │   │     # GRAPHIQUE PRINCIPAL :
│   │   │     #   Charger prices + indicators sur la période
│   │   │     #   (requêtes ZG-7)
│   │   │     #   components/charts.make_candlestick(df_prices)
│   │   │     #   Overlays configurables (checkboxes sidebar) :
│   │   │     #     EMA 20, EMA 50, EMA 200
│   │   │     #     Bollinger Bands
│   │   │     #     Ichimoku Cloud
│   │   │     #   Sous-graphiques (plotly make_subplots) :
│   │   │     #     Row 1 (70%) : chandelier + overlays
│   │   │     #     Row 2 (15%) : volume + volume_sma_20
│   │   │     #     Row 3 (15%) : RSI 14 avec lignes 30/70
│   │   │     #   Note : MACD optionnel (toggle sidebar)
│   │   │     #          Remplace RSI si activé
│   │   │     #
│   │   │     # MÉTRIQUES CLÉS (st.columns x4 x2 lignes) :
│   │   │     #   ATR 14 abs | ATR 14 % | Vol 30j ann | Beta 60j
│   │   │     #   Liquidité moy 20j | Dist 52w High | Squeeze | %B
│   │   │     #
│   │   │     # HISTORIQUE SIGNAUX (tableau 30j) :
│   │   │     #   Date | Score | Edges | Direction | Force
│   │   │
│   │   └── 03_qualite_data.py
│   │         # Requêtes complètes définies dans ZG-7
│   │         # CACHE ttl=300 (plus frais que les autres pages)
│   │         #
│   │         # STATUT PIPELINE (3 colonnes) :
│   │         #   Dernière exécution : date + heure
│   │         #   Statut : 🟢/🟡/🔴
│   │         #   Durée totale
│   │         #
│   │         # MÉTRIQUES INGESTION (4 colonnes) :
│   │         #   Tickers OK / Total
│   │         #   Tickers en erreur
│   │         #   Lignes insérées
│   │         #   % de succès
│   │         #
│   │         # GRAPHIQUE HISTORIQUE QUALITÉ (30j) :
│   │         #   Bar chart : pct_ok par jour
│   │         #   Couleur verte si > 90%, orange si > 70%, rouge sinon
│   │         #
│   │         # TICKERS EN ERREUR :
│   │         #   Tableau expandable (st.expander)
│   │         #   Ticker | Erreur | Depuis quand
│   │         #
│   │         # TROUS DE DONNÉES :
│   │         #   Requête ZG-7 trous
│   │         #   Tableau : Ticker | Jours manquants | Dernière date
│   │         #
│   │         # SANTÉ DB :
│   │         #   Requête user_segments
│   │         #   Gauge : X MB / 20 GB utilisés
│   │         #   Nb lignes par table
│   │
│   └── components/
│       ├── charts.py
│       │     # make_candlestick(df_prices, df_indicators,
│       │     #                  overlays=[], show_macd=False)
│       │     #   Utilise plotly make_subplots
│       │     #   rows=3 si pas MACD, rows=4 si MACD
│       │     #   row_heights=[0.60, 0.15, 0.15, 0.10]
│       │     #   Thème dark : template="plotly_dark"
│       │     #   Retourne fig plotly
│       │     #
│       │     # make_score_gauge(score, label) → fig plotly
│       │     #   go.Indicator mode="gauge+number"
│       │     #   Couleurs : vert > 70, orange 50-70, rouge < 50
│       │     #
│       │     # make_quality_bar(df_quality) → fig plotly
│       │     #   Bar chart historique qualité 30j
│       │
│       └── filters.py
│             # render_screener_filters(df) → df_filtered
│             #   Contient TOUS les filtres dans st.sidebar
│             #   Applique les filtres sur le DataFrame
│             #   Retourne df_filtered
│             #   Utilise st.session_state pour mémoriser les valeurs
│             #   entre les reruns sans reset involontaire
│
├── scheduler/
│   └── pipeline.py
│         # Logique complète définie dans ZG-5
│         # Point d'entrée unique du cron
│         # Gestion lock file
│         # Orchestration fetch → indicators → signals
│         # Log centralisé job_logs
│
├── scripts/
│   ├── bootstrap_db.py
│   │     # Lire tous les fichiers db/schema/*.sql
│   │     # dans l'ordre numérique (sorted)
│   │     # Pour chaque fichier SQL :
│   │     #   Lire le contenu
│   │     #   Exécuter via db.execute()
│   │     #   Logger le résultat
│   │     # Oracle n'a pas CREATE TABLE IF NOT EXISTS
│   │     # Utiliser :
│   │     #   BEGIN
│   │     #     EXECUTE IMMEDIATE 'CREATE TABLE ...';
│   │     #   EXCEPTION
│   │     #     WHEN OTHERS THEN
│   │     #       IF SQLCODE != -955 THEN RAISE; END IF;
│   │     #       -- ORA-00955 = table already exists
│   │     #   END;
│   │
│   ├── bootstrap_history.py
│   │     # Appelle fetch_prices.run(mode='bootstrap')
│   │     # Puis calculator.run(mode='bootstrap')
│   │     # Affiche progression avec tqdm
│   │     # Rapport final dans console + job_logs
│   │     # Durée estimée : 30-60 minutes
│   │     # Lancer dans tmux ou screen sur la VM :
│   │     #   tmux new -s bootstrap
│   │     #   python scripts/bootstrap_history.py
│   │     #   Ctrl+B D pour détacher
│   │
│   ├── migrate_db.py
│   │     # Exécuté à chaque deploy (deploy.yml)
│   │     # 1. Vérifier que table db_migrations existe
│   │     #    (la créer si non)
│   │     # 2. Lister fichiers dans db/migrations/*.sql
│   │     #    triés par ordre numérique
│   │     # 3. Pour chaque fichier :
│   │     #    SELECT COUNT(*) FROM db_migrations
│   │     #    WHERE migration_file = :filename
│   │     #    Si déjà appliqué → skip
│   │     #    Si pas appliqué :
│   │     #      Exécuter le SQL
│   │     #      INSERT INTO db_migrations
│   │     #        (migration_file, applied_at, applied_by)
│   │     #        VALUES (:f, SYSTIMESTAMP, 'deploy')
│   │     #    Si erreur SQL → rollback + exit(1)
│   │     #      (bloque le deploy, voulu)
│   │
│   ├── integrity_check.py
│   │     # Vérifications complètes chaque dimanche
│   │     # 1. Jours manquants par ticker (calendar.py)
│   │     # 2. Cohérence prices/indicators/signals
│   │     #    (dates présentes dans prices mais absentes indicators)
│   │     # 3. NULL anormaux (trop de NULL dans indicators = bug calcul)
│   │     # 4. Espace DB (requête user_segments)
│   │     # 5. Tickers actifs sans données depuis > 5j
│   │     # Tout loggé dans job_logs (job_name='integrity_check')
│   │     # Visible dans dashboard page Qualité
│   │
│   ├── backfill.py
│   │     # Usage :
│   │     #   python scripts/backfill.py --ticker TTE.PA \
│   │     #     --from 2023-01-01 --to 2024-01-01
│   │     #   python scripts/backfill.py --all \
│   │     #     --from 2024-01-01
│   │     # Refetch prices sur la période
│   │     # Recalcule indicators sur la période
│   │     # Regénère signals sur la période
│   │     # Utile après ajout nouveaux tickers
│   │     # ou correction données erronées
│   │
│   ├── ticker_reminder.py
│   │     # Exécuté trimestriellement
│   │     # INSERT INTO job_logs :
│   │     #   job_name = 'ticker_reminder'
│   │     #   status = 'INFO'
│   │     #   error_summary = 'Rappel : vérifier composition indices'
│   │     # Visible dans dashboard page Qualité
│   │     # Action manuelle requise : mettre à jour les JSON si besoin
│   │
│   └── validate_json_schema.py
│         # Exécuté dans ci.yml (Job 3)
│         # Pas de connexion Oracle
│         # Lire tous data/tickers/*.json
│         # Vérifier pour chaque ticker :
│         #   Champs obligatoires présents
│         #   Format ISIN valide (regex: [A-Z]{2}[A-Z0-9]{10})
│         #   Format pays valide (regex: [A-Z]{2})
│         #   Exchange dans liste autorisée
│         #   Suffixe ticker cohérent avec exchange
│         # Exit(1) si erreur → bloque le CI
│
├── tests/
│   ├── conftest.py
│   │     # Fixtures pytest :
│   │     #
│   │     # sample_ohlcv_df :
│   │     #   DataFrame 300 jours de données propres
│   │     #   Générées avec np.random pour être réalistes
│   │     #   Prix synthétiques avec tendance + bruit
│   │     #
│   │     # sample_ohlcv_df_with_errors :
│   │     #   Même chose avec anomalies injectées :
│   │     #     Ligne 50 : high < low (R01)
│   │     #     Ligne 100 : close = 0 (R13)
│   │     #     Ligne 150 : variation 300% (R15)
│   │     #     Ligne 200 : volume = 0 (R10)
│   │     #
│   │     # mock_db (pytest fixture) :
│   │     #   Mock de OracleDB
│   │     #   Remplace les vraies requêtes par des retours in-memory
│   │     #   Utiliser unittest.mock.patch ou pytest-mock
│   │     #   Tous les tests utilisent ce mock
│   │     #   Pas de connexion Oracle réelle en CI
│   │
│   ├── test_validate_ohlcv.py
│   │     # test_valid_data_passes()
│   │     #   df propre → is_valid = True pour toutes les lignes
│   │     #
│   │     # test_r01_high_less_than_low()
│   │     #   Injecter high < low → is_valid = False, flags contient "R01"
│   │     #
│   │     # test_r13_close_zero()
│   │     #   close = 0 → is_valid = False
│   │     #
│   │     # test_r15_extreme_variation()
│   │     #   variation 300% → is_valid = False
│   │     #
│   │     # test_r08_suspect_variation_warning()
│   │     #   variation 30% → is_valid = True, flags contient "R08"
│   │     #
│   │     # test_r10_volume_zero_warning()
│   │     #   volume = 0 → is_valid = True, flags contient "R10"
│   │     #
│   │     # test_first_row_no_variation_check()
│   │     #   Première ligne → R08/R09/R15 ignorées (pas de prev_close)
│   │
│   ├── test_indicators.py
│   │     # test_rsi_bounds()
│   │     #   RSI toujours entre 0 et 100 sur données sample
│   │     #
│   │     # test_ema200_nan_insufficient_data()
│   │     #   df avec 50 lignes seulement → ema_200 = NaN (pas d'erreur)
│   │     #
│   │     # test_bb_ordering()
│   │     #   bb_upper > bb_middle > bb_lower toujours (sans NaN)
│   │     #
│   │     # test_atr_positive()
│   │     #   ATR toujours > 0 sur données valides
│   │     #
│   │     # test_high_52w_gte_close()
│   │     #   high_52w >= close pour toutes les lignes (sans NaN)
│   │     #
│   │     # test_stoch_bounds()
│   │     #   Stochastique entre 0 et 100
│   │     #
│   │     # test_calculator_order_dependencies()
│   │     #   Vérifier que keltner n'est pas NaN quand atr est valide
│   │     #   (keltner dépend de ATR, ordre de calcul correct)
│   │
│   ├── test_scoring.py
│   │     # test_score_bounds()
│   │     #   Tous les scores entre 0 et 100
│   │     #
│   │     # test_global_score_weighted_sum()
│   │     #   Vérifier que global = somme pondérée exacte
│   │     #   (arrondi à 0.01 près)
│   │     #
│   │     # test_liquidity_filter()
│   │     #   Si liquidity < 500k → global_score = 0
│   │     #
│   │     # test_edge_pullback_requires_trend()
│   │     #   edge_pullback = False si trend_score < 65
│   │     #
│   │     # test_score_details_json_valid()
│   │     #   score_details est un JSON valide parseable
│   │     #   Contient les clés attendues
│   │     #
│   │     # test_edge_count_correct()
│   │     #   edges_count = nb d'edges à True dans le dict
│   │
│   ├── test_calendar.py
│   │     # test_christmas_not_trading()
│   │     #   is_trading_day(date(2024,12,25), "XPAR") = False
│   │     #
│   │     # test_saturday_not_trading()
│   │     #   is_trading_day(samedi, "XPAR") = False
│   │     #
│   │     # test_monday_is_trading()
│   │     #   is_trading_day(lundi non férié, "XPAR") = True
│   │     #
│   │     # test_get_last_trading_day_weekend()
│   │     #   Appel le dimanche → retourne le vendredi
│   │
│   └── test_json_schema.py
│         # test_all_ticker_files_valid_schema()
│         #   Appelle validate_json_schema.py logique
│         #   Vérifie que tous les JSON passent la validation
│         #
│         # test_isin_format()
│         #   ISIN valide : "FR0014000MR3" → OK
│         #   ISIN invalide : "FR123" → Erreur
│         #
│         # test_ticker_suffix_coherent_with_exchange()
│         #   XPAR + ".PA" → OK
│         #   XPAR + ".AS" → Erreur
│
├── deploy/
│   ├── setup_vm.sh       # Contenu complet dans ZG-4
│   ├── nginx.conf        # Config complète dans ZG-4 (dans setup_vm.sh)
│   └── pea-dashboard.service  # Contenu complet dans ZG-4
│
├── requirements.txt
│     yfinance>=0.2.36
│     pandas>=2.2.0
│     numpy>=1.26.0
│     pandas-ta>=0.3.14b
│     python-oracledb>=2.1.0
│     plotly>=5.18.0
│     streamlit>=1.32.0
│     python-dotenv>=1.0.0
│     loguru>=0.7.2
│     pytest>=8.0.0
│     pytest-mock>=3.12.0
│     ruff>=0.3.0
│     tqdm>=4.66.0
│
├── .env.example
│     # Copier en .env sur la VM, ne jamais commiter .env
│     ORACLE_USER=ADMIN
│     ORACLE_PASSWORD=
│     ORACLE_DSN=                    # ex: mondb_tp
│     ORACLE_WALLET_PATH=/wallet
│     ORACLE_WALLET_PASSWORD=
│     APP_ENV=production             # production / development
│     LOG_LEVEL=INFO
│     MIN_LIQUIDITY_EUR=500000
│     YFINANCE_BATCH_SIZE=50
│     YFINANCE_SLEEP_BETWEEN_BATCHES=5
│     YFINANCE_TIMEOUT=30
│     YFINANCE_MAX_RETRIES=3
│     YFINANCE_HISTORY_YEARS=5
│     PIPELINE_LOCK_FILE=/tmp/pea_pipeline.lock
│     PIPELINE_ABORT_FAIL_RATIO=0.5
│
├── .gitignore
│     .env
│     /wallet/
│     data/tickers_validated.json
│     __pycache__/
│     .pytest_cache/
│     *.pyc
│     /venv/
│     *.log
│     .DS_Store
│     *.egg-info/
│     dist/
│     build/
│
└── README.md
      # Description du projet
      # Architecture (diagram ASCII)
      # Prérequis (compte Oracle, Python 3.11)
      # Setup Phase 0 (lien deploy/setup_vm.sh)
      # Premier déploiement (séquence ZG-3)
      # Variables d'environnement (.env.example)
      # Bootstrap (bootstrap_db + bootstrap_history)
      # CI/CD (comment ça marche)
      # Ajouter des tickers (modifier JSON + validate)
      # Ajouter un indicateur (étapes)
      # Ajouter un edge (étapes)
      # Ajouter une migration DB (format + process)
      # Troubleshooting courant
```

---

## Schéma Base de Données Complet

### Table : market_calendars
```sql
BEGIN EXECUTE IMMEDIATE '
CREATE TABLE market_calendars (
  id            NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  exchange      VARCHAR2(10)  NOT NULL,
  holiday_date  DATE          NOT NULL,
  holiday_name  VARCHAR2(100),
  CONSTRAINT uq_calendar UNIQUE (exchange, holiday_date)
)'; EXCEPTION WHEN OTHERS THEN
  IF SQLCODE != -955 THEN RAISE; END IF; END;
```

### Table : referentiel_tickers
```sql
-- Colonnes clés vs V2 :
--   + is_index NUMBER(1) DEFAULT 0
--     (pour ^FCHI, ^AEX, ^BFX — fetchés pour beta,
--      exclus du screener)
--   + last_price_date DATE
--     (mis à jour après chaque fetch réussi,
--      évite une requête MAX sur prices à chaque run)

CREATE TABLE referentiel_tickers (
  id                   NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ticker_yfinance      VARCHAR2(20)  NOT NULL,
  ticker_display       VARCHAR2(20),
  nom                  VARCHAR2(100),
  isin                 VARCHAR2(12),
  pays                 VARCHAR2(5),
  indice_principal     VARCHAR2(30),
  indices_appartenance VARCHAR2(300),
  segment              VARCHAR2(20),
  exchange             VARCHAR2(10),
  eligible_pea         NUMBER(1)     DEFAULT 1,
  is_index             NUMBER(1)     DEFAULT 0,
  actif                NUMBER(1)     DEFAULT 1,
  last_price_date      DATE,
  liquidity_filter_ok  NUMBER(1),
  date_ajout           DATE          DEFAULT SYSDATE,
  date_derniere_verif  DATE,
  notes                VARCHAR2(500),
  CONSTRAINT uq_ticker UNIQUE (ticker_yfinance)
);
CREATE INDEX idx_ref_actif   ON referentiel_tickers(actif, is_index);
CREATE INDEX idx_ref_indice  ON referentiel_tickers(indice_principal);
```

### Table : prices
```sql
CREATE TABLE prices (
  id               NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ticker_yfinance  VARCHAR2(20)   NOT NULL,
  price_date       DATE           NOT NULL,
  open             NUMBER(12,4),
  high             NUMBER(12,4),
  low              NUMBER(12,4),
  close            NUMBER(12,4),
  close_adjusted   NUMBER(12,4),
  volume           NUMBER(20),
  is_valid         NUMBER(1)      DEFAULT 1,
  validation_flags VARCHAR2(100),
  validation_notes VARCHAR2(500),
  created_at       TIMESTAMP      DEFAULT SYSTIMESTAMP,
  updated_at       TIMESTAMP      DEFAULT SYSTIMESTAMP,
  CONSTRAINT uq_price UNIQUE (ticker_yfinance, price_date)
);
CREATE INDEX idx_prices_ticker_date ON prices(ticker_yfinance, price_date DESC);
CREATE INDEX idx_prices_date        ON prices(price_date DESC);
CREATE INDEX idx_prices_valid       ON prices(is_valid, price_date DESC);
```

### Table : indicators_daily
```sql
CREATE TABLE indicators_daily (
  id                  NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ticker_yfinance     VARCHAR2(20) NOT NULL,
  price_date          DATE         NOT NULL,
  -- TREND
  ema_8               NUMBER(12,4), ema_13        NUMBER(12,4),
  ema_20              NUMBER(12,4), ema_50         NUMBER(12,4),
  ema_200             NUMBER(12,4), sma_20         NUMBER(12,4),
  sma_50              NUMBER(12,4), sma_200        NUMBER(12,4),
  adx_14              NUMBER(8,4),  adx_plus_di    NUMBER(8,4),
  adx_minus_di        NUMBER(8,4),
  ichimoku_tenkan     NUMBER(12,4), ichimoku_kijun    NUMBER(12,4),
  ichimoku_senkou_a   NUMBER(12,4), ichimoku_senkou_b NUMBER(12,4),
  ichimoku_chikou     NUMBER(12,4),
  -- MOMENTUM
  rsi_2               NUMBER(8,4),  rsi_7          NUMBER(8,4),
  rsi_14              NUMBER(8,4),
  macd_line           NUMBER(12,6), macd_signal    NUMBER(12,6),
  macd_hist           NUMBER(12,6),
  roc_5               NUMBER(8,4),  roc_10         NUMBER(8,4),
  roc_20              NUMBER(8,4),
  stoch_k             NUMBER(8,4),  stoch_d        NUMBER(8,4),
  williams_r          NUMBER(8,4),
  rsi_div_bullish     NUMBER(1),    rsi_div_bearish NUMBER(1),
  -- VOLATILITE
  atr_14              NUMBER(12,4), atr_14_pct     NUMBER(8,4),
  bb_upper            NUMBER(12,4), bb_middle      NUMBER(12,4),
  bb_lower            NUMBER(12,4), bb_width       NUMBER(8,4),
  bb_pct_b            NUMBER(8,4),
  kc_upper            NUMBER(12,4), kc_middle      NUMBER(12,4),
  kc_lower            NUMBER(12,4),
  squeeze_signal      NUMBER(1),    squeeze_hist   NUMBER(12,6),
  volatility_30d_ann  NUMBER(8,4),
  -- VOLUME
  obv                 NUMBER(20),
  obv_trend_5d        NUMBER(1),    obv_trend_10d  NUMBER(1),
  volume_sma_20       NUMBER(20),   volume_ratio   NUMBER(8,4),
  mfi_14              NUMBER(8,4),  vwap_20d       NUMBER(12,4),
  liquidity_eur       NUMBER(20),   liquidity_eur_avg20 NUMBER(20),
  -- STRUCTURE
  pivot_pp            NUMBER(12,4), pivot_r1       NUMBER(12,4),
  pivot_r2            NUMBER(12,4), pivot_s1       NUMBER(12,4),
  pivot_s2            NUMBER(12,4),
  high_52w            NUMBER(12,4), low_52w        NUMBER(12,4),
  high_20d            NUMBER(12,4), low_20d        NUMBER(12,4),
  pct_from_52w_high   NUMBER(8,4),  pct_from_52w_low NUMBER(8,4),
  gap_pct             NUMBER(8,4),  gap_type       VARCHAR2(10),
  -- QUALITE
  beta_60d            NUMBER(8,4),
  created_at          TIMESTAMP DEFAULT SYSTIMESTAMP,
  CONSTRAINT uq_indicators UNIQUE (ticker_yfinance, price_date)
);
CREATE INDEX idx_ind_ticker_date ON indicators_daily(ticker_yfinance, price_date DESC);
CREATE INDEX idx_ind_date        ON indicators_daily(price_date DESC);
```

### Table : signals
```sql
CREATE TABLE signals (
  id               NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  ticker_yfinance  VARCHAR2(20) NOT NULL,
  signal_date      DATE         NOT NULL,
  -- SCORES
  trend_score      NUMBER(5,2), momentum_score   NUMBER(5,2),
  volume_score     NUMBER(5,2), structure_score  NUMBER(5,2),
  volatility_score NUMBER(5,2), global_score     NUMBER(5,2),
  -- EDGES
  edge_pullback    NUMBER(1) DEFAULT 0,
  edge_breakout    NUMBER(1) DEFAULT 0,
  edge_squeeze     NUMBER(1) DEFAULT 0,
  edge_divergence  NUMBER(1) DEFAULT 0,
  edge_mean_rev    NUMBER(1) DEFAULT 0,
  edges_count      NUMBER(2) DEFAULT 0,
  -- SYNTHESE
  signal_direction VARCHAR2(10),
  signal_strength  VARCHAR2(10),
  -- FILTRES
  liquidity_ok     NUMBER(1),
  data_ok          NUMBER(1),
  -- DETAIL JSON
  score_details    CLOB,
  CONSTRAINT uq_signal  UNIQUE (ticker_yfinance, signal_date),
  CONSTRAINT chk_scores CHECK (
    global_score BETWEEN 0 AND 100
    AND trend_score BETWEEN 0 AND 100
    AND momentum_score BETWEEN 0 AND 100
    AND volume_score BETWEEN 0 AND 100
    AND structure_score BETWEEN 0 AND 100
    AND volatility_score BETWEEN 0 AND 100
  ),
  CONSTRAINT chk_json   CHECK (score_details IS JSON)
);
CREATE INDEX idx_sig_score  ON signals(signal_date DESC, global_score DESC);
CREATE INDEX idx_sig_edges  ON signals(signal_date,
  edge_pullback, edge_breakout, edge_squeeze,
  edge_divergence, edge_mean_rev);
```

### Table : job_logs
```sql
CREATE TABLE job_logs (
  id               NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_name         VARCHAR2(100) NOT NULL,
  job_mode         VARCHAR2(20),
  started_at       TIMESTAMP     NOT NULL,
  finished_at      TIMESTAMP,
  duration_seconds NUMBER(10,2),
  status           VARCHAR2(20),
  tickers_total    NUMBER,
  tickers_ok       NUMBER,
  tickers_failed   NUMBER,
  rows_inserted    NUMBER,
  rows_updated     NUMBER,
  error_summary    VARCHAR2(500),
  error_details    CLOB,
  created_at       TIMESTAMP DEFAULT SYSTIMESTAMP,
  CONSTRAINT chk_job_status CHECK (
    status IN ('RUNNING','SUCCESS','PARTIAL','FAILED','INFO')
  )
);
CREATE INDEX idx_logs_job_date ON job_logs(job_name, started_at DESC);
CREATE INDEX idx_logs_status   ON job_logs(status, started_at DESC);
```

### Table : db_migrations
```sql
CREATE TABLE db_migrations (
  id             NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  migration_file VARCHAR2(100) NOT NULL,
  applied_at     TIMESTAMP DEFAULT SYSTIMESTAMP,
  applied_by     VARCHAR2(50),
  CONSTRAINT uq_migration UNIQUE (migration_file)
);
```

---

## Roadmap par Étapes

### ÉTAPE 0 — Infrastructure Oracle Cloud
```
□ Créer compte Oracle Cloud
    → oracle.com/cloud/free
    → Carte bancaire requise (0 débit si Always Free)
    → Choisir région la plus proche (Frankfurt ou Paris)

□ Provisionner VM ARM A1
    → Compute → Instances → Create Instance
    → Shape : VM.Standard.A1.Flex
    → OCPU : 4 / RAM : 24 GB
    → OS : Canonical Ubuntu 22.04
    → Boot volume : 50 GB
    → Ajouter votre clé SSH publique
    → Noter l'IP publique

□ Provisionner Autonomous Database
    → Oracle Database → Autonomous Database → Create
    → Type : Transaction Processing
    → Always Free : ON
    → Nom : pea_quant_db
    → Password admin : choisir un mot de passe fort
    → Télécharger Instance Wallet (bouton DB Connection)
    → Noter le DSN (fichier tnsnames.ora dans le wallet)

□ Configurer VCN Security List
    → Networking → Virtual Cloud Networks → VCN → Security Lists
    → Ajouter Ingress Rules :
        Source 0.0.0.0/0, TCP, Port 80
        Source 0.0.0.0/0, TCP, Port 443
        Source votre_IP/32, TCP, Port 22 (SSH restreint à votre IP)

□ Tester connexion SSH sur la VM
    ssh -i ~/.ssh/pea_quant_vm ubuntu@VM_IP

□ Créer repo GitHub public
    → github.com/new
    → Nom : pea-quant
    → Public
    → Initialiser avec README
```

### ÉTAPE 1 — Setup VM
```
□ Uploader et exécuter setup_vm.sh (contenu complet dans ZG-4)
    scp deploy/setup_vm.sh ubuntu@VM_IP:/tmp/
    ssh ubuntu@VM_IP "sudo bash /tmp/setup_vm.sh"

□ Uploader Oracle Wallet
    scp Wallet_pea_quant_db.zip peaquant@VM_IP:/wallet/
    ssh peaquant@VM_IP
    cd /wallet && unzip Wallet_pea_quant_db.zip && rm *.zip
    chmod 600 /wallet/*
    cat /wallet/tnsnames.ora  ← noter le nom du service _tp

□ Cloner le repo sur la VM
    ssh peaquant@VM_IP
    cd /app/pea-quant
    git clone https://github.com/votre-user/pea-quant.git .

□ Installer les dépendances initiales
    /app/pea-quant/venv/bin/pip install -r requirements.txt

□ Créer le .env
    cp /app/pea-quant/.env.example /app/pea-quant/.env
    nano /app/pea-quant/.env
    → Remplir ORACLE_USER, PASSWORD, DSN, WALLET_PATH, WALLET_PASSWORD

□ Configurer GitHub Secrets
    → Settings → Secrets → Actions → New repository secret
    VM_HOST = IP publique VM
    VM_USER = peaquant
    VM_SSH_KEY = contenu ~/.ssh/pea_quant_vm (clé PRIVÉE)
    ORACLE_USER = ADMIN
    ORACLE_PASSWORD = votre_password
    ORACLE_DSN = pea_quant_db_tp (depuis tnsnames.ora)
    ORACLE_WALLET_PASSWORD = password_wallet

□ Tester le deploy automatique
    git commit --allow-empty -m "chore: test deploy pipeline"
    git push origin main
    → Vérifier GitHub Actions que le job deploy passe
```

### ÉTAPE 2 — CI/CD
```
□ Écrire .github/workflows/ci.yml
    3 jobs : lint, test, validate-tickers-json
    Tous sur ubuntu-latest, Python 3.11
    Pas de connexion Oracle (mocks)

□ Écrire .github/workflows/deploy.yml
    Séquence exacte définie dans ZG-1
    needs: [lint, test, validate-tickers-json]
    Utiliser appleboy/ssh-action@v1.0.0

□ Écrire scripts/validate_json_schema.py
    Valider le format des tickers JSON
    Exit(1) si erreur

□ Écrire tests/conftest.py avec fixtures et mocks DB

□ Vérifier que CI passe sur une PR test
    git checkout -b test/ci-check
    git push origin test/ci-check
    → Créer PR → vérifier que les 3 jobs CI passent
    → Merger → vérifier que deploy passe aussi
```

### ÉTAPE 3 — Référentiel Tickers
```
□ Constituer data/tickers/cac40.json (40 tickers)
    Source : https://fr.wikipedia.org/wiki/CAC_40
    Vérifier chaque suffixe .PA sur finance.yahoo.com

□ Constituer data/tickers/cac_next20.json (20 tickers)
    Source : Wikipedia CAC Next 20

□ Constituer data/tickers/aex.json (25 tickers)
    Source : Wikipedia AEX
    Suffixe .AS pour Amsterdam
    Attention : certaines valeurs (ASML, Stellantis)
    → vérifier éligibilité PEA (siège UE)

□ Constituer data/tickers/bel20.json (20 tickers)
    Source : Wikipedia BEL 20
    Suffixe .BR pour Bruxelles

□ Constituer data/market_calendars/xpar.json
    Jours fériés Euronext Paris 2024 et 2025
    Source : euronext.com/en/trade/trading-hours-holidays

□ Constituer data/market_calendars/xams.json
□ Constituer data/market_calendars/xbru.json

□ Coder core/config.py
□ Coder core/db.py (connexion Oracle thin mode)
□ Coder core/logger.py (loguru + job_logs)
□ Coder core/calendar.py

□ Coder ingestion/validate_tickers.py
□ Exécuter localement ou sur VM :
    python ingestion/validate_tickers.py
    → Analyser le rapport
    → Corriger les tickers KO dans les JSON

□ Coder scripts/bootstrap_db.py
□ Exécuter sur la VM :
    ssh peaquant@VM_IP
    cd /app/pea-quant
    /app/pea-quant/venv/bin/python scripts/bootstrap_db.py
    → Vérifier que les 7 tables sont créées

□ Insérer les tickers validés en DB :
    Ajouter fonction dans bootstrap_db.py ou script séparé
    INSERT INTO referentiel_tickers depuis tickers_validated.json
    + INSERT ^FCHI, ^AEX, ^BFX avec is_index=1

□ Écrire tests/test_calendar.py et tests/test_json_schema.py
□ CI doit passer
```

### ÉTAPE 4 — Ingestion des Prix
```
□ Coder ingestion/validate_ohlcv.py
    Implémenter R01 à R15 exactement
    Tests unitaires associés dans test_validate_ohlcv.py

□ Coder ingestion/fetch_prices.py
    Mode delta + mode bootstrap
    FetchResult dataclass
    Batch 50 + sleep + retry exponentiel
    Fetch aussi les indices ^FCHI, ^AEX, ^BFX

□ Coder scripts/bootstrap_history.py

□ Écrire tests/test_validate_ohlcv.py (toutes les règles)
□ CI doit passer avec les tests
□ Push sur main → deploy automatique

□ Lancer le bootstrap historique sur VM :
    ssh peaquant@VM_IP
    tmux new -s bootstrap
    cd /app/pea-quant
    /app/pea-quant/venv/bin/python scripts/bootstrap_history.py
    → Ctrl+B D pour détacher (tourne en arrière-plan)
    → Suivre dans /var/log/pea-quant/pipeline.log
    → Durée estimée : 30-60 min pour 105 tickers

□ Vérifier en DB :
    SELECT COUNT(*) FROM prices;
    → attendu : ~105 tickers x ~1300 jours = ~136 500 lignes

□ Tester le mode delta manuellement :
    /app/pea-quant/venv/bin/python ingestion/fetch_prices.py
    → Doit fetcher seulement depuis last_price_date

□ Vérifier le lendemain que le cron 19h a fonctionné
```

### ÉTAPE 5 — Calcul des Indicateurs
```
□ Coder indicators/_base.py
    INDICATOR_WINDOWS complet (depuis ZG-3)
    check_min_periods() et get_lookback()

□ Coder indicators/trend.py + tests unitaires
□ Coder indicators/volatility.py + tests unitaires
    Attention : ordre ATR → Keltner → Squeeze
□ Coder indicators/momentum.py + tests unitaires
    Inclure detect_rsi_divergence() (algo ZG-6)
□ Coder indicators/volume.py + tests unitaires
□ Coder indicators/structure.py + tests unitaires
□ Coder indicators/quality.py + tests unitaires
    Charger les indices ^FCHI/^AEX/^BFX depuis DB

□ Coder indicators/calculator.py
    Mode delta + bootstrap
    Ordre de calcul respecté (volatility avant keltner/squeeze)
    Récupérer GLOBAL_LOOKBACK=400 jours depuis DB

□ Écrire tests/test_indicators.py complets
□ CI doit passer
□ Push → deploy

□ Lancer bootstrap calculator sur VM :
    tmux new -s calc
    /app/pea-quant/venv/bin/python indicators/calculator.py \
      --mode bootstrap
    → Durée estimée : 15-30 min

□ Vérifier indicators_daily en DB :
    SELECT COUNT(*) FROM indicators_daily;
    Vérifier quelques valeurs connues :
    RSI entre 0 et 100 ?
    EMA200 NULL pour les jeunes tickers ? (normal)
```

### ÉTAPE 6 — Signals et Scoring
```
□ Coder signals/scoring.py
    5 scores avec logique graduelle (V2 + ZG)
    check_liquidity() et check_data_quality()
    calc_global_score() avec pondérations config

□ Coder signals/edges.py
    5 edges : pullback, breakout, squeeze, divergence, mean_rev
    detect_all_edges() orchestrateur
    determine_direction() et determine_strength()

□ Coder signals/generator.py
    GenResult dataclass
    Construction score_details JSON complet
    MERGE INTO signals

□ Écrire tests/test_scoring.py
□ CI doit passer
□ Push → deploy

□ Exécuter generator manuellement sur VM :
    /app/pea-quant/venv/bin/python signals/generator.py

□ Analyser les résultats en DB :
    SELECT ticker_yfinance, global_score, signal_direction,
           edge_pullback, edge_breakout, edges_count
    FROM signals
    WHERE signal_date = (SELECT MAX(signal_date) FROM signals)
    ORDER BY global_score DESC
    FETCH FIRST 20 ROWS ONLY;

    → Les résultats semblent-ils cohérents ?
    → Ajuster seuils dans config.py si besoin

□ Vérifier le pipeline complet :
    Tester manuellement scheduler/pipeline.py
    /app/pea-quant/venv/bin/python scheduler/pipeline.py
    → Vérifier job_logs en DB
    → Vérifier que les 3 étapes s'enchaînent bien
```

### ÉTAPE 7 — Dashboard Streamlit
```
□ Coder dashboard/components/charts.py
    make_candlestick() avec plotly make_subplots
    Thème dark financier (template="plotly_dark")
    make_score_gauge()
    make_quality_bar()

□ Coder dashboard/components/filters.py
    render_screener_filters(df) → df_filtered
    Gestion session_state pour mémoriser les filtres

□ Coder dashboard/pages/01_screener.py
    Requête SQL complète (ZG-7)
    Tableau avec on_select="rerun"
    Navigation vers fiche (session_state + switch_page)
    Export CSV

□ Coder dashboard/pages/02_fiche_action.py
    Récupération ticker depuis session_state
    Graphique interactif avec sélecteur période
    Score cards et edges détectés
    Historique signaux 30j

□ Coder dashboard/pages/03_qualite_data.py
    Toutes les requêtes ZG-7
    Statut pipeline, trous de données, santé DB

□ Coder dashboard/app.py
    Config page + sidebar avec statut pipeline

□ Tester en local :
    streamlit run dashboard/app.py
    Vérifier connexion Oracle fonctionne
    Vérifier navigation screener → fiche
    Vérifier graphiques s'affichent correctement
    Vérifier filtres mémorisés entre reruns

□ Push → deploy automatique
    → Service systemd restart pea-dashboard
    → curl health check dans deploy.yml

□ Accéder au dashboard :
    http://VM_IP:8501 (si pas encore de domaine)
    ou https://votre-domaine.com si DNS configuré

□ Corriger les bugs d'affichage
□ Vérifier performance :
    Chargement screener < 3 secondes (avec cache)
    Chargement fiche action < 5 secondes
```

### ÉTAPE 8 — Scripts de Maintenance
```
□ Coder scripts/migrate_db.py
    Idempotent, lit db/migrations/
    Exit(1) si migration échoue (bloque deploy)

□ Coder scripts/integrity_check.py
    5 vérifications listées dans le plan

□ Coder scripts/backfill.py
    Arguments --ticker, --all, --from, --to

□ Coder scripts/ticker_reminder.py
    Simple INSERT dans job_logs

□ Tester integrity_check manuellement :
    /app/pea-quant/venv/bin/python scripts/integrity_check.py
    Vérifier le résultat dans dashboard page Qualité

□ Tester backfill sur 1 ticker :
    /app/pea-quant/venv/bin/python scripts/backfill.py \
      --ticker TTE.PA --from 2024-01-01

□ Vérifier que le cron dimanche fonctionne la semaine suivante
```

### ÉTAPE 9 — Extension Niveau 2 (~300 tickers)
```
□ Constituer les JSON Niveau 2 :
    data/tickers/sbf120.json     (~80 nouveaux tickers)
    data/tickers/cac_mid60.json  (~60 nouveaux tickers)
    data/tickers/amx.json        (~25 nouveaux tickers)
    data/tickers/bel_mid.json    (~20 nouveaux tickers)
    Sources : Wikipedia + vérification manuelle

□ Exécuter validate_tickers.py sur les nouveaux
□ Corriger les tickers KO (suffixes yfinance souvent incorrects)

□ Insérer nouveaux tickers en DB :
    INSERT INTO referentiel_tickers ...

□ Exécuter backfill.py pour les nouveaux tickers :
    /app/pea-quant/venv/bin/python scripts/backfill.py \
      --all --from 2019-01-01
    → Lancer dans tmux, durée ~30-60 min

□ Surveiller job_logs : taux d'erreur acceptable ?
□ Surveiller espace DB :
    SELECT segment_type, SUM(bytes)/1024/1024 AS mb
    FROM user_segments GROUP BY segment_type;

□ Vérifier filtre liquidité :
    Mid caps souvent < 500k EUR/jour
    Doivent scorer 0 → exclus du screener
    Vérifier dans dashboard

□ Total univers : ~300 tickers actifs
```

### ÉTAPE 10 — Extension Niveau 3 + Optimisations (~500 tickers)
```
□ Constituer les JSON Niveau 3 :
    data/tickers/cac_small.json     (~150 tickers)
    data/tickers/pan_european.json  (N100, Next150)

□ Même processus bootstrap que Niveau 2

□ Total univers : ~500 tickers

□ Vérifier performances pipeline complet :
    Mesurer durée dans job_logs
    Fetch delta 500 tickers : objectif < 15 min
    Calculator delta : objectif < 10 min
    Generator : objectif < 5 min
    Total : doit finir avant minuit (commencé à 19h)

□ Si trop lent → optimiser fetch_prices.py :
    Augmenter BATCH_SIZE à 75 si rate limit le permet
    Réduire SLEEP_BETWEEN_BATCHES à 3s si stable

□ Surveiller espace DB :
    500 tickers x 250j x ~1 an : +0.5 GB
    Largement dans 20 GB

□ Ajouter page dashboard "Vue par Indice" :
    dashboard/pages/04_vue_indices.py
    Score moyen par indice/segment
    Répartition des edges détectés
    Heatmap des scores par segment
```

---

## Règles de Contribution et Évolution

```
AJOUTER UN INDICATEUR
  1. indicators/famille.py : ajouter la fonction calc_xxx()
  2. Ajouter dans INDICATOR_WINDOWS (core/config.py)
  3. Ajouter dans l'ordre de calcul (indicators/calculator.py)
  4. Créer migration SQL : db/migrations/00X_add_xxx_column.sql
  5. Ajouter dans le scoring si pertinent (signals/scoring.py)
  6. Ajouter test dans tests/test_indicators.py
  7. Push PR → CI → deploy automatique

AJOUTER UN EDGE
  1. signals/edges.py : nouvelle fonction detect_edge_xxx()
  2. Ajouter dans detect_all_edges()
  3. Créer migration : db/migrations/00X_add_edge_xxx.sql
  4. Ajouter dans generator.py (MERGE statement)
  5. Ajouter filtre dans dashboard/components/filters.py
  6. Ajouter colonne dans screener (01_screener.py)
  7. Ajouter test dans tests/test_scoring.py
  8. Push PR → CI → deploy automatique

AJOUTER DES TICKERS
  1. Modifier JSON dans data/tickers/
  2. Exécuter validate_tickers.py en local
  3. Corriger les tickers KO
  4. Commit + push (CI validate le schema JSON)
  5. Sur VM : INSERT nouveaux tickers en DB
  6. Sur VM : python scripts/backfill.py --ticker XXX.PA

MODIFIER LE SCORING
  1. signals/scoring.py : ajuster seuils ou pondérations
  2. core/config.py : si les seuils sont configurables
  3. Push PR → CI → deploy automatique
  4. Le lendemain : vérifier les nouveaux scores en dashboard

AJOUTER UNE MIGRATION DB
  1. Créer db/migrations/00X_description.sql
  2. Script idempotent (gérer ORA-01430 column already exists)
  3. Push → deploy → migrate_db.py l'applique automatiquement
  4. Si migration échoue → deploy bloqué (voulu, corriger le SQL)
```

---

## Points de Vigilance Permanents

```
ORACLE FREE TIER
  → Surveiller l'espace DB depuis dashboard page Qualité
  → Ne jamais laisser la VM inactive > 7 jours
    (risque de suspension, se connecter en SSH si besoin)
  → Wallet expire parfois → retélécharger depuis Console Oracle
    et remplacer dans /wallet/ sur la VM
  → Les connexions Oracle ont un timeout idle
    → gérer ORA-03113 dans core/db.py avec retry

YFINANCE
  → API non officielle, peut changer sans préavis
  → Toujours vérifier DataFrame non vide avant traitement
  → Si trop d'erreurs soudaines → investiguer avant de continuer
  → Les tickers européens changent parfois de suffixe
    → validate_tickers.py détecte ça au trimestre

CALCUL INDICATEURS
  → EMA 200 nécessite 400 jours min → NULL sinon, pas d'erreur
  → Ne jamais interpréter NULL comme 0 dans le scoring
  → check_data_quality() protège contre les NULL critiques
  → Après ajout d'un indicateur : recalcul bootstrap nécessaire

SCORING ET EDGES
  → Un score élevé ≠ recommandation d'achat
  → Réévaluer les seuils après 1 mois de données réelles
  → Documenter chaque changement de seuil dans Git (commit message)
  → score_details JSON permet de comprendre chaque décision

PIPELINE
  → Le lock file /tmp/pea_pipeline.lock est perdu au reboot
    → c'est voulu, le cron le recréera au prochain run
  → Si le pipeline plante à 19h30, le lock reste
    → vérifier manuellement si le lock est bloquant
    → rm /tmp/pea_pipeline.lock si pipeline mort
  → Surveiller la durée dans job_logs
    Si durée augmente → univers de tickers grossit ou rate limit

CI/CD
  → Jamais pusher directement sur main sans PR
  → Les tests doivent couvrir tous les cas limites
  → Une migration DB ratée bloque le deploy (voulu)
  → Toujours tester en local avant push
  → Le deploy.yml fait git reset --hard
    → tout ce qui n'est pas commité sur main est perdu sur la VM
    → le .env et /wallet/ sont hors du repo, pas touchés
```