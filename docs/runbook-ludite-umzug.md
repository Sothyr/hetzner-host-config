# Runbook: Ludite auf die alte VM umziehen

Ziel: HAProxy statt nginx an Port 80 und 443. Alte Seiten bleiben hinter nginx. Neue Plattform und Ludite laufen daneben mit Docker.
Kein Hochskalieren. Die VM hat 3,5 GB RAM. Das Ergebnis der Speicherprobe in Schritt 5 entscheidet, ob es reicht.

Stand 22.11.2026: Der Umzug ist gelaufen. Die Schritte 0 bis 6 sind auf der VM erprobt. Schritt 7 (Abbau) steht aus. Jeder Schritt hat einen Rückweg.

## 0. Vorher

- DNS A- und AAAA-Einträge auf `159.69.212.10` und `2a01:4f8:1c1e:a32c::1` für `neu.`, `cms-neu.`, `auth-neu.`, `tickets-neu.`, `stats-neu.ludite-kisslegg.de`. Die Namen für den Go-Live (`auth.`, `tickets.`, `stats.`, `cms.`) gleich mit anlegen.
- **IPv6 prüfen, bevor ein AAAA-Eintrag gesetzt wird.** Auf der VM war die Adresse nie an `eth0` gesetzt. Besucher mit IPv6 liefen ins Leere. Behoben mit `nmcli connection modify "Wired connection 1" ipv6.method manual ipv6.addresses 2a01:4f8:1c1e:a32c::1/64 ipv6.gateway fe80::1`, danach `nmcli device reapply eth0`. Test: `curl -6 -sI https://<domain>`.
- Hetzner-Backup der VM statt Snapshot (Entscheidung vom 22.11.).
- Mailversand: siehe Abschnitt "Mail" weiter unten. Port 25 ist ausgehend offen (IPv4 getestet).
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

Die Vereins-`.env` entsteht aus der Dev-`.env` (`.env.dev`) mit einem Skript: Zugangsdaten neu erzeugen, nur Namen, Mail- und Kalenderwerte übernehmen. Pflichtwerte für die Plattform: `SMTP_HOST=mail`, `SMTP_PORT=25`, `PRETIX_URL=http://pretix:80`, `PRETIX_PUBLIC_URL=<öffentliche pretix-Adresse>` (sonst antwortet pretix "Unknown host"), `MAIL_FROM`, `CONTACT_TO`.

- `SITE_URL=https://neu.ludite-kisslegg.de`, `CMS_URL=https://cms-neu.ludite-kisslegg.de`
- `WORDPRESS_MEM_LIMIT=256m`, `API_MEM_LIMIT=160m`, `FRONTEND_MEM_LIMIT=96m`. Die API liegt im Betrieb bei etwa 120 MB.
- `PRETIX_WEB_WORKERS=1` und `PRETIX_CELERY_WORKERS=1` in `platform.env`.
- Node.js muss auf der VM installiert sein (`sudo dnf install -y nodejs`), sonst bricht der Aufruf beim Login-Design ab.
- **Testadressen in `site.config.json`:** Das Frontend baut `cms.{domain}` aus dem Hostnamen. Auf `neu.` entstünde `cms.neu.`. Für den Test `urls` in der Instanz-`site.config.json` auf die `-neu`-Namen festsetzen (Kopie als `.orig` sichern). Beim Go-Live die Kopie zurückspielen.

```
python3 tools/rebuild.py --instance instances/ludite-kisslegg --engine docker
python3 tools/rebuild.py --instance instances/ludite-kisslegg --engine docker --people
```

Die alten Inhalte (Mitglieder, Spiele, Fragen, Ergebnisse) kommen über die Admin-Seiten `/de/admin/plays` und `/de/admin/ranking`. Das Konto braucht die Rolle `vorstand` im Realm. Dann im Browser testen: Seite, Anmeldung, Tickets, Statistik, Kontaktformular, Testmail.

## 5. Speicherprobe

```
free -m
docker stats --no-stream
```

Gut: `available` bleibt über 400 MB, Swap wird kaum genutzt. Schlecht: Swap füllt sich oder Container werden beendet. Dann Umzug stoppen. Server in der Hetzner-Konsole hochskalieren ist jederzeit möglich, ebenso Umami weglassen (ist schon aus).

## 6. Ludite live schalten

DNS zeigt schon auf diese VM. Es ändert sich nur das Routing. Vorher Dump von `ludite-database` sichern (`docker exec ludite-database sh -c 'pg_dumpall -U "$POSTGRES_USER"' | gzip > ludite-db-DATUM.sql.gz`) und `/etc/nginx/conf.d/ludite-kisslegg.de.conf` kopieren. Beides auf den PC holen.

1. Werte ändern, `.env`-Dateien vorher kopieren:
   - `platform.env`: `AUTH_URL`, `STATS_URL`, `PRETIX_BASE_URL` auf `https://auth.`, `stats.`, `tickets.ludite-kisslegg.de`.
   - Vereins-`.env`: `SITE_URL`, `SITE_WWW_URL`, `CMS_URL`, `PRETIX_PUBLIC_URL`, `MAIL_LOGO_URL` auf die echten Adressen.
   - `python3 tools/doctor.py` prüft auch das DNS der neuen Namen.
2. `python3 tools/rebuild.py --platform --engine docker`, warten bis Keycloak `healthy` ist.
3. Die Kopie `site.config.json.orig` zurück nach `site.config.json`, dann `python3 tools/rebuild.py --instance instances/ludite-kisslegg --engine docker`.
4. `platform-hosts.txt` sichern und durch die sechs neuen Namen ersetzen (`ludite-kisslegg.de`, `www.`, `cms.`, `auth.`, `tickets.`, `stats.`). `sudo haproxy -c -V -f /etc/haproxy/haproxy.cfg`, dann `sudo systemctl reload haproxy`. Die Seite ist etwa eine Minute weg, bis Caddy die Zertifikate hat.
5. Prüfen: alle sechs Adressen mit `curl -s -o /dev/null -w '%{http_code}'`. Erwartet 200, bei `auth.` 302.

**Keycloak:** Der Register-Job ergänzt bei einem bestehenden Realm die Adressen der Clients (`ensureClientUrls`, ab Commit 067b58f). Ohne diese Version kommt beim Login "Invalid parameter: redirect_uri". Dann von Hand in Keycloak beim Client `site` die Weiterleitungen, Web-Origins und Post-Logout-Adressen ergänzen, ebenso `wordpress` mit `https://cms.ludite-kisslegg.de/*`.

**WordPress:** Mit `wp search-replace 'cms-neu.ludite-kisslegg.de' 'cms.ludite-kisslegg.de' --all-tables --dry-run` prüfen, ob importierte Seiten noch die Testadresse enthalten.

**Speicher sparen:** Die alten Container nach dem Umschalten anhalten (`docker update --restart=no`, `docker stop`), nicht löschen. Das brachte auf der VM rund 400 MB. Der Rückweg bleibt: `docker start` und die alte `platform-hosts.txt` zurückspielen.

Den Block `/etc/nginx/conf.d/ludite-kisslegg.de.conf` entfernt erst Schritt 7.

## 7. Altes Ludite entfernen (erst nach einigen Tagen)

Container laut Messung: `ludite-database`, `ludite-frontend`, `ludite-backend`, `ludite-security` (der alte Keycloak, Port 8083), `ludite-mail`, `ludite-vvt-foundry` und `solo-rpgs` (die Seite `rpg.`, Port 8085 oder 8082, vorher prüfen). Alles geht weg, auch `rpg.`.

Vorher sichern: Datenbank-Dump von `ludite-database` und die Volumes. Dann die Container stoppen, eine Woche liegen lassen, danach löschen. Den Azure-Agent entfernen, wenn er nicht mehr gebraucht wird. Der GitHub-Runner bleibt.

Danach die Zertifikate der entfernten Namen löschen, damit certbot sie nicht weiter erneuert: `sudo certbot delete --cert-name <name>` für `ludite-kisslegg.de`, `www.ludite-kisslegg.de`, `vault.`, `idm.`, `vtt.` und `rpg.ludite-kisslegg.de`. Die Namen vorher mit `certbot certificates` ansehen.

## 8. Zertifikate der alten Seiten (certbot)

Alle Zertifikate laufen mit `authenticator = nginx`. Nach dem Umbau findet der Plugin keine Server-Blöcke auf Port 80, denn nginx hört auf 8180. Der Dry-Run scheitert dann mit 404. Getestet auf der VM: Mit `http01_port = 8180` klappt die Erneuerung.

```
sudo sh -c "sed -i '/^\[renewalparams\]/a http01_port = 8180' /etc/letsencrypt/renewal/*.conf"
sudo sh -c "grep -c http01_port /etc/letsencrypt/renewal/*.conf"    # hinter jeder Datei eine 1
sudo certbot renew --dry-run
```

Das `sudo sh -c` ist nötig, weil der Ordner nur für root lesbar ist. Den `sed` nur einmal ausführen.
Neue Zertifikate für nginx-Seiten mit `certbot --nginx --http-01-port 8180 ...` anfordern.
Fehler bei Zertifikaten der entfernten Namen (`vault`, `vtt`, `idm`, `rpg`) sind erwartet, sie werden in Schritt 7 gelöscht.

## Mail

Eigener Postfix mit OpenDKIM im Container `mail` (Profil `mail`, `SMTP_HOST=mail`). Kein Relay.

- Ausgehend Port 25 ist bei diesem Hetzner-Konto offen. Test auf IPv4, nicht nur `/dev/tcp` mit Hostname: `timeout 8 bash -c 'echo > /dev/tcp/<IPv4>/25'`.
- DNS: `mail` A, SPF (`v=spf1 ... ip4:159.69.212.10 ...`, nur ein SPF-Eintrag), `mail._domainkey` mit dem Schlüssel aus `/var/lib/dkim/<domain>/mail.txt` im Container, `_dmarc` (`p=none`).
- **Reverse-DNS** der IPv4 in der Hetzner Console auf `mail.ludite-kisslegg.de`. Ohne ihn landen Mails bei Gmail im Spam.
- OpenDKIM signiert nur mit `InternalHosts` auch Mails anderer Container. Das steht im Entrypoint (Commit 7a7ab33). Prüfen: Gmail "Original anzeigen" zeigt SPF, DKIM und DMARC `PASS`.
- Posteingang des Absenders: `@` MX zeigt auf die VM, der Postfix nimmt aber keine Post an. Antworten und Bounces an `noreply@` gehen verloren. Antworten kommen über die Reply-To-Adresse beim Verein an.
- Neue Absender landen zunächst im Spam. Beim Vereinskonto einen Filter "nie als Spam" für `ludite-kisslegg.de` anlegen.

## Rückwege

| Problem | Rückweg |
|---|---|
| Alte Seiten nach Schritt 2 kaputt | `sudo ./nginx-behind-haproxy.sh restore` |
| Plattform frisst Speicher | `python3 tools/rebuild.py --platform --engine docker --stop` und Hochskalieren erwägen |
| Ludite live kaputt | Namen aus `platform-hosts.txt` entfernen, reload HAProxy. nginx und alte Container laufen noch. |
| Alles | Snapshot zurückspielen |
