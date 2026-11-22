# Runbook: Ludite auf die alte VM umziehen

Ziel: HAProxy statt nginx an Port 80 und 443. Alte Seiten bleiben hinter nginx. Neue Plattform und Ludite laufen daneben mit Docker.
Kein Hochskalieren. Die VM hat 3,5 GB RAM. Das Ergebnis der Speicherprobe in Schritt 5 entscheidet, ob es reicht.

Stand: Skripte und Konfig sind im Repo, aber noch nie auf der VM gelaufen. Jeder Schritt hat einen Rückweg.

## 0. Vorher

- DNS A-Einträge (und AAAA) auf `159.69.212.10` für `neu.`, `cms-neu.`, `auth-neu.`, `tickets-neu.`, `stats-neu.ludite-kisslegg.de`.
- Frischer Hetzner-Snapshot der VM.
- rDNS und A-Eintrag für `mail.ludite-kisslegg.de` (nur nötig, wenn Mails an echte Empfänger gehen sollen).
- Login: SSH auf Port 2693.

## 1. Vorbereitung (Besucher merken nichts)

Swap anlegen. Falls `fallocate` bei `swapon` scheitert, mit `dd if=/dev/zero of=/swapfile bs=1M count=2048` neu anlegen.

```
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -m
```

Foundry aus lassen:

```
docker update --restart=no ludite-vvt-foundry && docker stop ludite-vvt-foundry
```

Prüfen:

```
docker compose version          # mindestens 2.24, sonst versteht Compose "!override" nicht
python3 --version && git --version
dnf info haproxy                # Paket muss im Repo sein
docker inspect watchtower --format '{{.Args}} {{.Config.Env}}'   # Watchtower darf die neuen Container nicht automatisch aktualisieren
```

HAProxy installieren, noch nicht starten:

```
sudo dnf install -y haproxy
sudo git clone https://github.com/Sothyr/vereins-pages.git /srv/sothyr-pages   # bei privatem Repo mit Deploy-Key oder Token
sudo cp /etc/haproxy/haproxy.cfg /root/haproxy.cfg.original
sudo cp /srv/sothyr-pages/deploy/haproxy/edge.cfg.example /etc/haproxy/haproxy.cfg
printf '%s\n' neu.ludite-kisslegg.de cms-neu.ludite-kisslegg.de auth-neu.ludite-kisslegg.de \
  tickets-neu.ludite-kisslegg.de stats-neu.ludite-kisslegg.de | sudo tee /etc/haproxy/platform-hosts.txt
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

Skript auf die VM bringen (vom Rechner aus):

```
scp -P 2693 scripts/nginx-behind-haproxy.sh <user>@159.69.212.10:~
```

## 2. Umschalten auf HAProxy (alte Seiten nur Sekunden weg)

```
sudo ./nginx-behind-haproxy.sh convert   # Backup, listen-Zeilen umbauen, nginx -t. Reload noch nicht.
sudo ./nginx-behind-haproxy.sh switch    # nginx reload, HAProxy startet auf 80 und 443
sudo ./nginx-behind-haproxy.sh check     # jede Domain aus der nginx-Konfig ansprechen
```

Danach von außen prüfen: `curl -I https://sothyr.de`, `https://blut-und-spiele.at`, `https://tfg-waermetechnik.at`. Das Log von nginx muss echte Besucher-IPs zeigen.

Zurück: `sudo ./nginx-behind-haproxy.sh restore`. Das stoppt HAProxy und stellt nginx auf 80 und 443 zurück. `switch` rollt selbst zurück, wenn HAProxy nicht startet.

## 3. Plattform starten

```
cd /srv/sothyr-pages && cp platform.env.example platform.env && nano platform.env
```

Werte in `platform.env`:

- `EDGE=haproxy`, `HTTP_PORT=80`, `HTTPS_PORT=443`
- `AUTH_URL=https://auth-neu.ludite-kisslegg.de`, `STATS_URL=https://stats-neu.ludite-kisslegg.de`, `PRETIX_BASE_URL=https://tickets-neu.ludite-kisslegg.de`
- Alle Passwörter neu erzeugen, siehe Kommentar in der Datei.
- `SMTP_HOST=mail`, `SMTP_PORT=25`, `MAIL_FROM=tickets@ludite-kisslegg.de`, `MAIL_HOSTNAME=mail.ludite-kisslegg.de`, `MAIL_DKIM_DOMAINS=ludite-kisslegg.de`
- Speicher: `KEYCLOAK_HEAP=-Xmx400m`, `KEYCLOAK_MEM_LIMIT=700m`. Startwerte, beobachten.

```
python3 tools/doctor.py
python3 tools/rebuild.py --platform --engine docker
```

Das Log des Mail-Containers zeigt beim ersten Start den DKIM-Eintrag. Ihn als TXT `mail._domainkey.ludite-kisslegg.de` im Hetzner-DNS setzen.

## 4. Ludite als Testseite

In `instances/ludite-kisslegg/.env` (eigenes Repo, nach `instances/` klonen):

- `SITE_URL=https://neu.ludite-kisslegg.de`, `CMS_URL=https://cms-neu.ludite-kisslegg.de`
- `WORDPRESS_MEM_LIMIT`, `API_MEM_LIMIT`, `FRONTEND_MEM_LIMIT` setzen (zum Beispiel 200m, 150m, 64m, nach Messung anpassen).

```
python3 tools/rebuild.py --instance instances/ludite-kisslegg --engine docker
```

Die Domains stehen schon in `platform-hosts.txt`. Caddy holt die Zertifikate über HAProxy. Dann im Browser testen: Seite, Anmeldung, Tickets, Statistik, Testmail.

## 5. Speicherprobe

```
free -m
docker stats --no-stream
```

Gut: `available` bleibt über 400 MB, Swap wird kaum genutzt. Schlecht: Swap füllt sich oder Container werden beendet. Dann Umzug stoppen. Server in der Hetzner-Konsole hochskalieren ist jederzeit möglich, ebenso Umami weglassen (ist schon aus).

## 6. Ludite live schalten

DNS zeigt schon auf diese VM. Es ändert sich nur das Routing.

1. In `.env` des Vereins `SITE_URL=https://ludite-kisslegg.de`, `SITE_WWW_URL=https://www.ludite-kisslegg.de`, `CMS_URL=https://cms.ludite-kisslegg.de`. Der A-Eintrag `cms.` muss existieren.
2. Die drei Namen zu `/etc/haproxy/platform-hosts.txt` hinzufügen, `sudo systemctl reload haproxy`.
3. `python3 tools/rebuild.py --instance instances/ludite-kisslegg --engine docker`.

Zwischen Schritt 2 und dem Ende von 3 ist die Seite kurz weg, bis Caddy die Zertifikate hat (etwa eine Minute). Danach in `nginx` die alten Ludite-Server-Blöcke entfernen: `ludite-kisslegg.de`, `www`, `vault`, `idm`, `vtt`. Der Block `rpg.` bleibt, wenn `solo-rpgs` weiterlaufen soll. `nginx -t` und `systemctl reload nginx`.

## 7. Altes Ludite entfernen (erst nach einigen Tagen)

Container laut Messung: `ludite-database`, `ludite-frontend`, `ludite-backend`, `ludite-security`, `ludite-mail`, `ludite-vvt-foundry`. Vorher Daten sichern (Datenbank-Dump, Volumes). Dann stoppen, eine Woche liegen lassen, danach löschen. Den Azure-Agent entfernen, wenn er nicht mehr gebraucht wird. Der GitHub-Runner bleibt.

## 8. Zertifikate der alten Seiten (certbot)

Alle Zertifikate laufen mit `authenticator = nginx`. Ob der Plugin nach dem Umbau noch funktioniert, ist ungeprüft. Der Plugin sucht Server-Blöcke auf Port 80 und nginx hört jetzt auf 8180.

```
sudo certbot certificates                 # Ablaufdaten
sudo certbot renew --dry-run
```

Schlägt der Test fehl, in `/etc/letsencrypt/renewal/*.conf` unter `[renewalparams]` die Zeile `http01_port = 8180` ergänzen und den Test wiederholen. Hilft das nicht, auf `webroot` oder einen separaten Pfad umstellen. Die Zertifikate laufen erst in Wochen ab, es eilt nicht, aber vor dem Ablauf klären.

## Rückwege

| Problem | Rückweg |
|---|---|
| Alte Seiten nach Schritt 2 kaputt | `sudo ./nginx-behind-haproxy.sh restore` |
| Plattform frisst Speicher | `python3 tools/rebuild.py --platform --engine docker --stop` und Hochskalieren erwägen |
| Ludite live kaputt | Namen aus `platform-hosts.txt` entfernen, reload HAProxy. nginx und alte Container laufen noch. |
| Alles | Snapshot zurückspielen |
