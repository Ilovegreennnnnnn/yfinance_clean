# Oracle Wallet — dépôt et usage

Ce document résume la procédure recommandée pour le Wallet Oracle (Autonomous DB)
et son usage en mode `python-oracledb` thin, tel que décrit dans `plan.md`.

1) Télécharger le Wallet depuis Oracle Cloud Console
   - Database → votre DB → DB Connection → Download Wallet

2) Ne PAS committer le Wallet dans Git.
   - Le Wallet contient des fichiers sensibles. Il doit être uploadé MANUELLEMENT
     sur la VM de déploiement dans `/wallet`.

3) Uploader le ZIP sur la VM (exemple local→VM) :

```bash
scp -i ~/.ssh/pea_quant_vm Wallet_xxx.zip peaquant@VM_IP:/wallet/
```

4) Sur la VM :

```bash
ssh -i ~/.ssh/pea_quant_vm peaquant@VM_IP
cd /wallet && unzip Wallet_xxx.zip && rm Wallet_xxx.zip
chmod 600 /wallet/*
chown -R peaquant:peaquant /wallet
```

5) Variables d'environnement à définir dans `/app/pea-quant/.env` :

- `ORACLE_USER=ADMIN`
- `ORACLE_PASSWORD=...`
- `ORACLE_DSN=mondb_tp` (nom du service dans `tnsnames.ora`)
- `ORACLE_WALLET_PATH=/wallet`
- `ORACLE_WALLET_PASSWORD=...` (si applicable)

6) Connexion Python (mode thin) :

```python
import oracledb

conn = oracledb.connect(
    user=os.environ['ORACLE_USER'],
    password=os.environ['ORACLE_PASSWORD'],
    dsn=os.environ['ORACLE_DSN'],
    wallet_location=os.environ['ORACLE_WALLET_PATH'],
    wallet_password=os.environ.get('ORACLE_WALLET_PASSWORD'),
)
```

7) Notes pour GitHub Actions
   - Les tests unitaires n'utilisent pas la DB réelle ; mocks sont utilisés.
   - Si vous souhaitez des tests d'intégration, stockez les fichiers du Wallet
     encodés en base64 dans des Secrets séparés et décodez-les pendant le job.
