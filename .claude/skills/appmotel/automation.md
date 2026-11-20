# Appmotel 24x7 Automation

## Autopull

A systemd timer of the `appmotel` user runs `appmo autopull` every 2 minutes. For each app it pulls new commits and deploys them. It also scans the app logs for errors (auto-debug, see `docs/AUTO-DEBUG.md`).

```bash
appmo check            # which apps have new commits (no deploy)
appmo autopull         # run one cycle now
```

Operators only (`OPERATOR_USERS`):

```bash
sudo -u appmotel systemctl --user status appmotel-autopull.timer
sudo -u appmotel journalctl --user -u appmotel-autopull -n 50
```

## Monitoring checklist

1. `appmo status`: all apps, Traefik, and the TLS certificate expiry
2. `appmo logs <app> 100` for an app that is not `running`
3. `curl -s -o /dev/null -w '%{http_code}\n' https://<app>.<BASE_DOMAIN>/`: 200 from outside
4. `df -h /home`: disk space (each isolated app has its own home)
5. `journalctl -t appmo --since today`: who changed what

## Automated recovery

```bash
# Restart an app that is not running
if ! appmo status myapp 2>/dev/null | grep -q 'active (running)'; then
  appmo restart myapp
fi
```

Traefik restarts by itself on failure (systemd). To restart it by hand:

- members of `appmotel-users`: `appmo self-update` (it also restarts Traefik)
- operators: `sudo -u appmotel sudo systemctl restart traefik-appmotel`

## Logs

journald rotates the logs. Check the size with `journalctl --disk-usage`.
