# Appmotel Security Best Practices

## Never Run as Root

The `apps` user should never run commands directly as root — the three-tier model provides all necessary access:

```bash
# ❌ WRONG
sudo systemctl restart appmotel-myapp

# ✅ CORRECT
sudo -u appmotel systemctl --user restart appmotel-myapp
sudo -u appmotel sudo systemctl restart traefik-appmotel
```

## Protect Secrets

Never commit secrets or credentials to the repository. Keep them in `.env` files:

```bash
# Secrets live here (not in repo)
cat /home/appmotel/.config/appmotel/myapp/.env
# DATABASE_PASSWORD=secret123
# API_KEY=abc123xyz
```

## Validate Scripts Before Execution

```bash
bash -n script.sh                             # Syntax check
cat script.sh                                 # Review content
sudo -u appmotel bash -x script.sh            # Debug execution (-x traces each command)
```

## Use Backups Before Major Changes

```bash
sudo -u appmotel appmo backup myapp
sudo -u appmotel appmo update myapp
# If something breaks:
sudo -u appmotel appmo restore myapp
```
