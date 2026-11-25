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
| Operators: members of the group `appmotel-ops`, and the user `apps` | `sudo usermod -aG appmotel-ops <user>`, then log in again (more names: `OPERATOR_USERS` in `/home/appmotel/.config/appmotel/.env`, then `sudo bash install.sh`) | run any command as `appmotel`, `sudo su - appmotel` |
| root | | everything |
| isolated app users `a-<app>` | created by `appmo add --isolated` | nothing outside their own home |

- A member of `appmotel-users` controls **all** apps, because `appmo exec` runs any command in any app. Only trusted people belong in the group.
- In plain words: users deploy and manage apps through `appmo`; operators are the admins of appmotel itself and have the master key. A person in both groups is an operator.
- Operators can run `journalctl` and read the whole system journal (`install.sh` sets a read ACL on `/var/log/journal` for `appmotel-ops`). Users get app logs with `appmo logs`.
- To find your own rights, run `id` (is `appmotel-users` or `appmotel-ops` listed?) and `sudo -n -l`.
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

`appmo self-update` does not change sudo rules or groups. If an upgrade adds rights, a sysadmin must also run `sudo bash install.sh` from a checkout of the new version.

## Key patterns for Claude Code

- **Non-interactive:** all of this runs without a password. `appmo env myapp` (no more words) opens an editor, so do not use it in automation. Read and change the `.env` like this:
  ```bash
  appmo env myapp get PORT                 # prints the value, exit 1 if not set
  appmo env myapp set DEBUG false          # not secret: value on the command line is fine
  printf '%s' "$SECRET" | appmo env myapp set API_KEY   # one secret from stdin
  appmo env myapp set <<'EOF'              # many values from stdin, all or none
  DATABASE_URL=postgres://app:pw@db/app
  API_KEY=abc123
  EOF
  appmo restart myapp                      # once, after the last set
  ```
  `set` refuses values with `$(`, backticks, `;`, `&&`, `||` or a newline.
- **Secrets:** `.env` files hold secrets. Do not print them into logs, issues or commits. Read only the value you need (`appmo env myapp get KEY`).
- **Always give secrets on stdin** (a pipe or a here-doc with a quoted `'EOF'`), never as `set KEY VALUE`. A value on the command line is in the process list and in the sudo log; `set` warns when a name like `*PASS*`, `*TOKEN*`, `*KEY*` or `*SECRET*` gets its value that way. The appmo audit log hides values in all forms. To copy a secret from one app to another without printing it: `appmo env app1 get API_KEY | appmo env app2 set API_KEY`.
- **First `.env` of an app:** `appmo add` copies `.env.default` (or `env.default`, `.env.example`, `env.example`, `.env.local`) from the app's own folder. For a subfolder app, put the template in that subfolder: a template in a parent folder is not used.
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
