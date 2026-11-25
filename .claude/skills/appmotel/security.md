# Appmotel Security

## Use the smallest right

- Use `appmo`. It works with the group `appmotel-users`, needs no root, and is logged with your name (`journalctl -t appmo`).
- Do not use root for apps. `sudo systemctl restart appmotel-myapp` does not work: apps are systemd **user** services. Use `appmo restart myapp`.
- Commands as `appmotel` other than `appmo` need operator rights, and only the sudo log records them.

## Isolate apps that hold secrets

By default all apps run as `appmotel` and can read each other's `.env`. Deploy with `--isolated`, or move an app with `appmo isolate myapp`. Then the app runs as `a-myapp`, and it cannot read:

- other apps' files
- appmotel's `.env`
- `acme.json` (the TLS keys)

App ports (10001-59999) accept new connections only from the server itself (`appmotel-firewall.service`, nft table `inet appmotel`), so the only way in from outside is Traefik on 80/443. On the server, an isolated app user can connect only to its own app port; to reach another app it must use Traefik. Normal apps (user `appmotel`) can still reach each other. See `docs/ISOLATED-APPS.md`.

## Protect secrets

- Secrets belong in the app's `.env`, never in the repo.
- Read only what you need: `appmo env myapp get DATABASE_URL`. Do not paste `.env` content into issues, PRs, commits or chat.
- Set secrets from stdin, never as `appmo env myapp set KEY VALUE` (the sudo log keeps the command line): `printf '%s' "$S" | appmo env myapp set KEY`, or many lines with `appmo env myapp set <<'EOF' ... EOF`.
- For a private repo of an isolated app, appmotel copies its own GitHub SSH key into the app user's home. That key can read every repo that appmotel can read. Prefer a deploy key for each repo.

## Check scripts before you run them

```bash
bash -n script.sh        # syntax check
cat script.sh            # read it
```

## Back up before big changes

```bash
appmo backup myapp
appmo update myapp
appmo restore myapp      # if something breaks
```
