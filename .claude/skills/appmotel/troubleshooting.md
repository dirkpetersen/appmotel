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
