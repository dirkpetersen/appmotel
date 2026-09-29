# Appmotel Troubleshooting

## App Not Starting

```bash
sudo -u appmotel systemctl --user status appmotel-myapp
sudo -u appmotel journalctl --user -u appmotel-myapp -n 100
cat /home/appmotel/.config/appmotel/myapp/metadata.conf
cat /home/appmotel/.config/appmotel/myapp/.env
ss -tlnp | grep <port>
appmo restart myapp
```

## Traefik 404 Errors

```bash
ls -la /home/appmotel/.config/traefik/dynamic/
cat /home/appmotel/.config/traefik/dynamic/myapp.yaml
sudo -u appmotel sudo journalctl -u traefik-appmotel -f
curl http://localhost:<port>
sudo -u appmotel sudo systemctl restart traefik-appmotel
```

## Permission Issues

```bash
ls -la /home/appmotel/.config/appmotel/myapp/
ls -la /home/appmotel/.local/share/appmotel/myapp/
ps aux | grep appmotel
sudo cat /etc/sudoers.d/appmotel
sudo -u appmotel whoami                              # Should output: appmotel
sudo -u appmotel sudo systemctl status traefik-appmotel  # Should work
```

## Git Issues

```bash
sudo -u appmotel bash -c 'cd /home/appmotel/.local/share/appmotel/myapp/repo && git remote -v'
sudo -u appmotel bash -c 'cd /home/appmotel/.local/share/appmotel/myapp/repo && git branch'
sudo -u appmotel bash -c 'cd /home/appmotel/.local/share/appmotel/myapp/repo && git status'

# Force pull (discard local changes)
sudo -u appmotel bash -c 'cd /home/appmotel/.local/share/appmotel/myapp/repo && git fetch && git reset --hard origin/main'
```

## Expired or Expiring TLS Certificate

Browsers reject every app when the wildcard cert expires. `appmo status` (no app name) prints `TLS certificate: expires in N day(s)` / `EXPIRED ...`, and autopull logs a WARN 14 days out (`TLS_EXPIRY_WARN_DAYS`) and an ERROR once expired, at most once a day.

```bash
appmo status                                  # last line: TLS certificate expiry
sudo certbot certificates                     # which cert, which domains, expiry
sudo journalctl -u certbot --since "-3 days"  # why renewal is failing
sudo certbot renew --force-renewal --cert-name <name>
```

- Traefik reads the cert files once and never reloads them. `install.sh` (root pass) installs `/etc/letsencrypt/renewal-hooks/deploy/appmotel-restart-traefik`, which fixes permissions and restarts Traefik after each successful renewal. If that file is missing, restart by hand after renewing: `sudo -u appmotel sudo systemctl restart traefik-appmotel`.
- `The account is currently suspended` (InCommon/Sectigo ACME) cannot be fixed locally: the certificate admin must reactivate the ACME account or issue new EAB credentials.
- Certs from a `*.dev-ai...` + `*.arcs...` lineage may share one ACME account with a second cert, so a suspended account eventually breaks both.
