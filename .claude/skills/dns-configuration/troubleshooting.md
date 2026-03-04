# DNS Troubleshooting

## DNS Not Resolving

```bash
$ dig myapp.apps.yourdomain.edu
# Empty ANSWER SECTION indicates DNS not configured or not propagated yet
```

1. Wait for DNS propagation (TTL expiry, typically 5–60 minutes)
2. Verify DNS records in provider's control panel
3. Check for typos in domain names
4. Test with authoritative nameserver directly:
   ```bash
   dig @8.8.8.8 myapp.apps.yourdomain.edu
   dig @ns1.your-dns-provider.com myapp.apps.yourdomain.edu
   ```

## Certificate Errors (HTTPS Fails)

Symptoms: "Certificate not valid for this domain" or `curl` SSL errors.

1. Ensure DNS is resolving first — Let's Encrypt requires working DNS
2. Check Traefik logs:
   ```bash
   sudo journalctl -u traefik-appmotel -f | grep -i "certificate\|acme"
   ```
3. Verify Let's Encrypt config in `~/.config/appmotel/.env`:
   ```bash
   USE_LETSENCRYPT="yes"
   LETSENCRYPT_EMAIL="admin@yourdomain.edu"
   LETSENCRYPT_MODE="http"  # or "dns"
   ```
4. Check ACME storage permissions:
   ```bash
   ls -la ~/.local/share/traefik/acme.json
   # Must be: -rw------- (mode 600)
   ```

## 404 Errors on HTTPS

Symptoms: Certificate valid, but Traefik returns "404 page not found".

1. Verify app is running:
   ```bash
   appmo status myapp
   systemctl --user status appmotel-myapp
   ```
2. Check Traefik dynamic config:
   ```bash
   cat ~/.config/traefik/dynamic/myapp.yaml
   ```
3. Test app directly on its port:
   ```bash
   cat ~/.config/appmotel/apps/myapp/metadata.env | grep PORT
   curl http://localhost:8000/
   ```
4. Check Traefik routing logs:
   ```bash
   sudo journalctl -u traefik-appmotel -f | grep myapp
   ```
