# TLS Certificates

Every app gets HTTPS at `https://<app>.BASE_DOMAIN`. You do not have to issue or renew a certificate for each app yourself. appmotel uses one of two sources, in this order.

## 1. A wildcard certificate that you supply (certbot)

If `/etc/letsencrypt/live/<name>/` holds a certificate for exactly `*.BASE_DOMAIN`, appmotel uses it for all apps.

- `install.sh` finds it and writes `~/.config/traefik/dynamic/tls-config.yaml`, which makes it Traefik's default certificate. App routes then use `tls: {}`.
- A certificate for a different domain is never used. For example, with `BASE_DOMAIN=apps.example.edu`, a certificate for `*.other.example.edu` or `*.example.edu` is ignored. (`*.example.edu` does not cover `x.apps.example.edu`, because a wildcard covers only one label.)
- appmotel must be able to read the key. `install.sh` gives the `ssl-cert` group read access, and `/usr/local/bin/appmotel-fix-certs` does it again after a change.
- Renewal is certbot's job. `install.sh` installs a certbot deploy hook that restarts Traefik after a renewal, because Traefik reads these files only once at start.
- `appmo autopull` warns in the log 14 days before the certificate expires (`TLS_EXPIRY_WARN_DAYS`).

To issue such a wildcard yourself, certbot needs the DNS-01 challenge, for example:

```bash
sudo certbot certonly --dns-route53 -d '*.apps.example.edu'
sudo bash install.sh      # picks up the new certificate
```

## 2. Let's Encrypt through Traefik (ACME)

If there is no matching wildcard certificate and `USE_LETSENCRYPT=yes`, Traefik gets certificates from Let's Encrypt by itself:

- For each app route, Traefik asks Let's Encrypt for a certificate for that host name the first time a client connects. This takes a few seconds; until then, Traefik's default certificate is served.
- Traefik renews each certificate about 30 days before it expires. No cron job and no restart is needed.
- All certificates and the ACME account key are in `~/.local/share/traefik/acme.json` (mode 600, only `appmotel` can read it).
- A new app gets its certificate without any manual step. Removed apps keep their old certificate in `acme.json` until it expires; that is harmless.

You select how Let's Encrypt checks that you control the domain with `LETSENCRYPT_MODE`:

| `LETSENCRYPT_MODE` | How Let's Encrypt checks | Needs |
|---|---|---|
| `http` (default) | It fetches a token from `http://<app>.BASE_DOMAIN/.well-known/acme-challenge/` on port 80 | Port 80 open from the internet |
| `dns` | Traefik writes a TXT record in Route53 | Route53 zone, AWS credentials or an EC2 instance role. No inbound port is needed |

What you get depends on the mode. Let's Encrypt issues wildcard certificates only with the DNS-01 challenge:

- **`http`:** one certificate for each app host name. A new app has Traefik's default certificate for a few seconds, until its own certificate arrives.
- **`dns`:** one wildcard certificate, `*.BASE_DOMAIN` plus `BASE_DOMAIN`, for all apps. Every app route asks for the same certificate, and Traefik gets it only once. A new app has a valid certificate at once.

### DNS mode (Route53)

Traefik needs Route53 access, from an EC2 instance role or from `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in the `.env`. The role needs `route53:ListHostedZonesByName`, `route53:ChangeResourceRecordSets` and `route53:GetChange`.

Route53 is a global service, but the AWS SDK in Traefik needs a region. If `AWS_REGION` is not set, `install.sh` adds `AWS_REGION="us-east-1"` to the `.env`.

The first wildcard can take about 3 minutes, because Let's Encrypt waits until the TXT record is visible.

**Switching an existing server from `http` to `dns`:** set `LETSENCRYPT_MODE="dns"` and run `appmo self-update`. This rebuilds all app routes, and new apps get the wildcard. Existing apps keep their own certificates, because Traefik prefers a certificate for the exact host name. To move all apps to the wildcard at once, move the old certificates away:

```bash
sudo -u appmotel mv /home/appmotel/.local/share/traefik/acme.json /home/appmotel/.local/share/traefik/acme.json.old
sudo -u appmotel sudo systemctl restart traefik-appmotel
```

Until the wildcard arrives (about 3 minutes), clients see Traefik's default certificate. Do it at a quiet time.

### Turned on by default for new installs

When `install.sh` creates a new `~/.config/appmotel/.env` and finds no matching wildcard certificate, it sets `USE_LETSENCRYPT=yes` if:

- no other program listens on port 80, and
- ufw or firewalld, if active, allows port 80.

The server cannot test the firewalls outside the machine (for example an AWS security group or a campus firewall). If they block port 80, Traefik only logs failed attempts and serves its default certificate. Open port 80, or use `LETSENCRYPT_MODE=dns`.

An existing `.env` is never changed. To turn Let's Encrypt on later:

```bash
sudo -u appmotel nano /home/appmotel/.config/appmotel/.env
#   USE_LETSENCRYPT=yes
#   LETSENCRYPT_EMAIL=""         # optional (example.com addresses are rejected)
#   LETSENCRYPT_MODE="http"      # or "dns"
appmo self-update
```

### Rate limits

Let's Encrypt allows 50 new certificates for each registered domain per week. In `http` mode each app uses one, which is enough for most servers. If you add and remove many apps, use `dns` mode or a wildcard certificate from section 1.

## Check which certificate an app gets

```bash
echo | openssl s_client -connect myapp.apps.example.edu:443 -servername myapp.apps.example.edu 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

| Issuer | Meaning |
|---|---|
| `O=Let's Encrypt` and subject `CN=*.apps.example.edu` | Your certbot wildcard certificate (section 1) |
| `O=Let's Encrypt` and subject `CN=apps.example.edu` | Traefik's wildcard certificate in `dns` mode (section 2) |
| `O=Let's Encrypt` and subject `CN=myapp.apps.example.edu` | Traefik's certificate for this app in `http` mode (section 2) |
| `CN=TRAEFIK DEFAULT CERT` | No certificate yet. Wait a few seconds, then look at the Traefik log |

```bash
sudo journalctl -u traefik-appmotel -n 50 | grep -i acme
```
