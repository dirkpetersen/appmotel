# Appmotel 24x7 Automation

## Autopull Timer

Appmotel checks for git updates every 2 minutes:

```bash
sudo -u appmotel systemctl --user status appmotel-autopull.timer
sudo -u appmotel journalctl --user -u appmotel-autopull -n 50
sudo -u appmotel systemctl --user start appmotel-autopull.service  # manual trigger
```

## Monitoring Checklist

1. **App services:** `sudo -u appmotel appmo status`
2. **Traefik service:** `sudo -u appmotel sudo systemctl status traefik-appmotel`
3. **Autopull timer:** `sudo -u appmotel systemctl --user status appmotel-autopull.timer`
4. **Disk space:** `df -h /home/appmotel`
5. **Logs:** Check journalctl for errors

## Automated Recovery

```bash
# Restart app if not active
if ! sudo -u appmotel systemctl --user is-active appmotel-myapp >/dev/null 2>&1; then
  sudo -u appmotel systemctl --user restart appmotel-myapp
fi

# Restart Traefik if not active
if ! sudo -u appmotel sudo systemctl is-active traefik-appmotel >/dev/null 2>&1; then
  sudo -u appmotel sudo systemctl restart traefik-appmotel
fi
```

## Log Rotation

Systemd rotates logs automatically. Monitor disk usage:

```bash
sudo -u appmotel journalctl --disk-usage
cat /etc/systemd/journald.conf
```
