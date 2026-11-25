# Appmotel Troubleshooting

## `appmo` says "I'm sorry ... I can't do that" or asks for a password

You are not allowed to switch to `appmotel`. Check with `id`. If `appmotel-users` is missing, ask an admin to run `sudo usermod -aG appmotel-users <you>`, then log in again. If the group is listed but `appmo` still fails, the server needs `sudo bash install.sh` (the group rule came with a newer appmotel).

## App does not start

```bash
appmo status myapp                       # systemd state and last log lines
appmo logs myapp 100
appmo env myapp get PORT                 # the port the app must listen on
appmo exec myapp ls -la                  # repo, .venv, node_modules?
appmo restart myapp
```

- The app must listen on `$PORT` from its `.env`, on `127.0.0.1` or `0.0.0.0`.
- A Python app that wants another Python version: set `PYTHON_VERSION=3.12` in the `.env` (uv installs it), then run `appmo exec myapp rm -rf .venv` and `appmo update myapp`.

## App `.env` holds global settings (`BASE_DOMAIN`, `USE_LETSENCRYPT`, ...)

Apps that were added from a subfolder before Nov 2026 could get the parent folder's template as their `.env` (for example the appmotel examples got appmotel's own `.env.default`). The lines do no harm. To clean up: `appmo env myapp unset BASE_DOMAIN USE_LETSENCRYPT LETSENCRYPT_MODE` (name the keys you see; keep `PORT`), then `appmo restart myapp`.

## An isolated app cannot reach another app on localhost

This is intended: an isolated app user may connect only to its own app port on the server. Call the other app through Traefik (`https://other.<BASE_DOMAIN>`). Check the rule with `sudo nft list table inet appmotel` (sets `app_uids`, `own_ports`).

## 404 or 502 from Traefik

- **404 right after a deploy:** Traefik loads a new route about 1 second after it is written. Try again.
- **404 later:** the route is missing. `appmo list` must show the app. Run `appmo restart myapp`, which rebuilds the route of an isolated app.
- **502 Bad Gateway:** Traefik has the route, but the app does not answer on its port. See "App does not start".

## Apps reachable on the wrong network (second NIC)

Traefik listens on all addresses unless `APPMOTEL_BIND_IP` is set in `/home/appmotel/.config/appmotel/.env`. A sysadmin sets it to the IP of the primary card and runs `appmo self-update`. Never edit `traefik.yaml` by hand to change it: use the setting. Check with `ss -ltn '( sport = :443 )'`.

## Wrong or missing TLS certificate

```bash
echo | openssl s_client -connect myapp.<BASE_DOMAIN>:443 -servername myapp.<BASE_DOMAIN> 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

| Subject | Meaning |
|---|---|
| `CN=TRAEFIK DEFAULT CERT` | no certificate yet. Wait a few seconds (`dns` mode: up to 3 minutes). After 10 minutes autopull restarts Traefik once an hour to try again (log: `journalctl --user -u appmotel-autopull` as appmotel). If it stays in `http` mode, port 80 is probably closed from the internet |
| `CN=myapp.<BASE_DOMAIN>` | Traefik's Let's Encrypt certificate for this app (`http` mode) |
| `CN=<BASE_DOMAIN>` with `*.<BASE_DOMAIN>` | Traefik's wildcard certificate (`dns` mode, Route53) |
| `CN=*.<BASE_DOMAIN>` | a certbot wildcard certificate from the sysadmin |

- `appmo status` shows the expiry of a certbot certificate in its last line. Traefik renews its own certificates.
- The Traefik log (operators only, group `appmotel-ops`): `sudo -u appmotel sudo journalctl -u traefik-appmotel -n 50 | grep -i acme`
- A certbot certificate is only used if it is for exactly `*.<BASE_DOMAIN>`. Renewal is certbot's job (`sudo certbot certificates`, `sudo journalctl -u certbot`); a hook restarts Traefik after each renewal.
- Full details: `docs/TLS-CERTIFICATES.md`.

## Git problems

```bash
appmo exec myapp git remote -v
appmo exec myapp git status
appmo check myapp
```

Force the repo to the remote state (discards local changes in the repo, not the `.env`):

```bash
appmo backup myapp
appmo exec myapp sh -c 'git fetch && git reset --hard origin/main'
appmo update myapp
```

## Who changed something?

```bash
journalctl -t appmo --since "-1 day"      # user=<name> cmd=appmo ...
```
