---
name: appmotel
description: Managing Appmotel PaaS (apps on systemd + Traefik, deployed from GitHub) from a user account with the appmo command, for 24x7 automation with Claude Code
---

# Appmotel Management with appmo

## Rule 1: use `appmo`, without a prefix

Run `appmo <command>` directly. It switches to the `appmotel` user by itself (`sudo -u appmotel /home/appmotel/.local/bin/appmo ...`). Do not type `sudo -u appmotel appmo`.

`appmo` works the same way for normal apps and for isolated apps (apps that run as their own Linux user `a-<app>`). Raw commands such as `sudo -u appmotel systemctl --user ...` or `sudo -u appmotel cat ...` do not: they need operator rights and miss isolated apps, whose files are in `/home/a-<app>`. Use them only if no `appmo` command does the job.

## Who may do what

| Who | How set up | May do |
|---|---|---|
| Members of the group `appmotel-users` | `sudo usermod -aG appmotel-users <user>`, then log in again | run `appmo` (and nothing else) as `appmotel` |
| `OPERATOR_USERS` (default `apps`) | in `/home/appmotel/.config/appmotel/.env`, then `sudo bash install.sh` | run any command as `appmotel`, `sudo su - appmotel` |
| root | | everything |
| isolated app users `a-<app>` | created by `appmo add --isolated` | nothing outside their own home |

- A member of `appmotel-users` controls **all** apps, because `appmo exec` runs any command in any app. Only trusted people belong in the group.
- To find your own rights, run `id` (is `appmotel-users` listed?) and `sudo -n -l`.
- Every `appmo` command is logged with the real user name: `journalctl -t appmo` shows `user=joe as=appmotel cmd=appmo add ...`. sudo logs the same call too.
- `appmo skill`, `appmo help`, `-h` and `--help` run as yourself and do not switch users.

## Common operations

```bash
# Deploy
appmo add --isolated myapp username/repo main          # recommended: own user a-myapp
appmo add myapp https://github.com/username/repo main
appmo add myapp https://github.com/username/repo/tree/main/apps/myapp   # subfolder
appmo add mywiki username/my-zensical-wiki             # Zensical site
appmo isolate myapp                                    # move an existing app to its own user

# Look
appmo list                    # USER column: appmotel or a-<app>
appmo status                  # all apps, Traefik, TLS certificate expiry
appmo status myapp
appmo logs myapp 100
appmo check [myapp]           # are there new commits? (no deploy)

# Change
appmo restart myapp           # also after every .env change
appmo update myapp            # pull and deploy now (autopull does this every 2 min)
appmo stop|start myapp
appmo remove myapp            # keeps the .env as .env.backup for a later add

# Inside the app (works for isolated apps too; runs in the repo folder, venv active)
appmo exec myapp cat .env
appmo exec myapp git status
appmo exec myapp python manage.py migrate

# Backups
appmo backup myapp
appmo backups myapp
appmo restore myapp [2026-01-10-120000]

# Appmotel itself (CLI, Traefik binary, configs, all routes)
appmo self-update
```

## Key patterns for Claude Code

- **Non-interactive:** all of this runs without a password. `appmo env myapp` opens an editor, so do not use it in automation. Change the `.env` like this:
  ```bash
  appmo exec myapp sh -c 'echo "NEW_VAR=value" >> .env'
  appmo restart myapp
  ```
  To change an existing value, use `appmo exec myapp sed -i 's/^OLD=.*/OLD=new/' .env`.
- **Secrets:** `.env` files hold secrets. Do not print them into logs, issues or commits. Read only the line you need: `appmo exec myapp grep '^PORT=' .env`.
- **Multi-component apps:** `appmo restart myapp` restarts all components.
- **Never** `git rebase -i`, `git add -i` or other interactive commands.

## Install this skill for yourself

```bash
appmo skill        # downloads the latest skill to ~/.claude/skills/appmotel/
```

Restart Claude Code afterwards.

## Where things are

```
/home/appmotel/.config/appmotel/.env              # global config (BASE_DOMAIN, TLS, OPERATOR_USERS)
/home/appmotel/.config/appmotel/<app>/            # normal app: .env, metadata.conf
/home/appmotel/.config/appmotel/<app>/isolated.conf   # isolated app: only user and port
/home/a-<app>/.config/appmotel/<app>/             # isolated app: .env, metadata.conf
/home/appmotel/.config/traefik/dynamic/<app>.yaml # route of every app (written by appmotel only)
/home/appmotel/.local/share/traefik/acme.json     # Let's Encrypt certificates (Traefik)
```

These folders are mode 700. Reach them with `appmo exec` or `appmo status`, not with `cat`.

**See also:**
- [troubleshooting.md](troubleshooting.md): app does not start, 404, certificates, git problems
- [automation.md](automation.md): autopull, monitoring, recovery
- [security.md](security.md): rights, secrets, isolation, backups
- [testing.md](testing.md): clean install, syntax checks, test apps
