# Isolated Apps

This page is for the sysadmin who runs an appmotel server. Read it before you put apps with secrets on a shared server.

## The problem

By default, every app runs as the same Linux user, `appmotel`. So every app can read the files of every other app:

- the `.env` files of all apps (database passwords, API keys, tokens)
- appmotel's own `.env` (for example AWS keys for Route53)
- the TLS private keys in `acme.json`
- appmotel's GitHub SSH key

If one app has a bug that lets an attacker run code or read files, the attacker gets the secrets of **all** apps on the server.

## The solution: one Linux user for each app

An isolated app runs as its own Linux user, `a-<app>`. For example, the app `billing` runs as `a-billing`.

```bash
appmo add --isolated billing user/billing-repo        # new app
appmo isolate billing                                 # existing app
```

All other commands stay the same. `appmo start`, `stop`, `restart`, `update`, `logs`, `env`, `exec`, `status`, `check`, `backup`, `restore`, `backups`, `remove`, `list` and `autopull` work for isolated apps too.

### What an isolated app cannot do

| Attempt by the app user | Result |
|---|---|
| Read appmotel's `.env`, or the `.env` of another app | Permission denied |
| Read `acme.json` (TLS keys) or the Traefik config | Permission denied |
| Read the home of another app user | Permission denied |
| Use `sudo`, or become `appmotel` | Refused, the user has no sudo rights |
| Change Traefik routes (for example, take over the host name of another app) | Not possible, only `appmotel` writes routes |
| Run `appmo self-update` or `appmo isolate` | Refused |

All of these were tested on a real server.

### What isolation does NOT protect

- **Network:** app ports are closed to other machines (`appmotel-firewall.service`), but on the server itself an app user can still connect to `127.0.0.1:<port>` of every other app. Traefik's rate limits and any login that Traefik adds are not in that path. If an app trusts every request that comes from localhost, isolation does not protect it. Network isolation is planned (TBD).
- **CPU and memory:** isolated apps share the machine. `MEMORY_LIMIT` and `CPU_QUOTA` still apply per app.
- **appmotel itself:** whoever controls `appmotel` (or the operator user, `apps` by default) controls all isolated apps too. This is by design.
- **Private repos:** see [Private repos and SSH keys](#private-repos-and-ssh-keys).

## How it works

```
operator (apps) --sudo--> appmotel --sudo -u a-<app>--> a-<app>
                             |                             |
                         Traefik routes,             app files, venv,
                         isolated.conf               systemd user service
```

- **The app user:** `a-<app>`, with its own home `/home/a-<app>` (mode 700), member of the group `appmotel-apps`. Linger is on, so its systemd user services run without a login.
- **The root helper `/usr/local/bin/appmotel-user`:** creates and deletes app users. `appmotel` may run it with sudo. The helper:
  - accepts only valid app names (at most 30 characters)
  - never takes over a user that it did not create
  - refuses to finish if the new user would get any sudo rights
- **The control path:** `/etc/sudoers.d/appmotel-a-<app>` contains one line, `appmotel ALL=(a-<app>) NOPASSWD: ALL`. So `appmotel` can run anything as that user, and nothing in the other direction.
- **The operator rules:** the rules in `/etc/sudoers.d/appmotel` for the operators (`appmotel-ops`, `OPERATOR_USERS`) and for the group `appmotel-users` exclude the app users, `<operators>, !%appmotel-apps`. This also holds when `OPERATOR_USERS=ALL`, or when an app user is put into `appmotel-users` by mistake.
- **Two roles of `appmo`:** run as `appmotel`, it is in admin role. Run as an `a-*` user, it is in app role: it manages only the apps in that user's home, never switches to `appmotel`, and never writes Traefik config.
- **What appmotel keeps:** for an isolated app, appmotel keeps only `~/.config/appmotel/<app>/isolated.conf` (the user and the port). For each command, `appmo` runs itself as the app user. After the command, appmotel rebuilds the Traefik route from the app's port and `.env`. It checks every value first, so a changed `.env` cannot add routes for other host names.

### Where the files are

| What | Normal app | Isolated app |
|---|---|---|
| Repo, venv | `/home/appmotel/.local/share/appmotel/<app>/repo` | `/home/a-<app>/.local/share/appmotel/<app>/repo` |
| `.env`, metadata | `/home/appmotel/.config/appmotel/<app>/` | `/home/a-<app>/.config/appmotel/<app>/` |
| systemd unit | `/home/appmotel/.config/systemd/user/` | `/home/a-<app>/.config/systemd/user/` |
| Backups | `/home/appmotel/.local/share/appmotel-backups/<app>/` | `/home/a-<app>/.local/share/appmotel-backups/<app>/` |
| Traefik route | `/home/appmotel/.config/traefik/dynamic/<app>.yaml` | same (written by appmotel) |

## Upgrading an existing server

Do this once, from a checkout of the new appmotel version.

1. Run the system part as root. It creates the groups `appmotel-apps`, `appmotel-users` and `appmotel-ops`, installs `/usr/local/bin/appmotel-user` and writes the new sudoers rules:
   ```bash
   sudo bash install.sh
   ```
2. Run the user part as appmotel. It sets the new file modes and installs uv:
   ```bash
   sudo -u appmotel bash install.sh
   ```
3. Check the result:
   ```bash
   sudo cat /etc/sudoers.d/appmotel | grep appmotel-apps     # the exclusion is there
   sudo -u apps cat /home/appmotel/.config/appmotel/.env      # must say: Permission denied
   ```

Existing apps keep working unchanged. Move them one at a time with `appmo isolate <app>`.

**Changed behaviour after the upgrade:**

- appmotel's `~/.config`, data and backup folders are now mode 700, and all `.env` files mode 600. Before, any local user could read them. Scripts that read these files directly as another user (for example as `apps`) must now use `sudo -u appmotel cat ...` or `appmo exec <app> cat .env`.
- Tab completion of app names no longer works for the operator user, for the same reason.
- `appmo list` has a new USER column.

## Moving an app: `appmo isolate`

`appmo isolate <app>`:

1. Makes a backup of the app.
2. Creates the user and stops the old services.
3. Copies the repo into the new home, together with files that git does not track (for example SQLite databases or uploads). Venvs are not copied; they are built again.
4. Copies the app's `.env`.
5. Deploys the app as the new user on the same port and moves the route.

The URL stays the same. If any step fails, appmotel deletes the new user, restores the old route and starts the old services again.

The app is down while it is built again. That is a few seconds for small apps, about 1 to 2 minutes for a Next.js build.

The backup from step 1 stays in appmotel's backup folder, and `isolate` prints its path. `appmo restore` cannot use it after the move, because restore now runs as the app user. To go back to the old app: run `appmo remove <app>`, add the app again without `--isolated`, and copy the `.env` from that backup.

## Private repos and SSH keys

The app user has no GitHub access of its own.

- **Public repo:** appmotel clones it over HTTPS. No key is copied.
- **Private repo:** appmotel copies **its own GitHub SSH key** into `/home/a-<app>/.ssh/`. The app user can then read every repo that this key can read, not only its own. If that is not acceptable, use a separate deploy key for each repo. Until appmo supports that, you can put a deploy key in `/home/a-<app>/.ssh/` yourself and remove the copied key.

appmotel treats a repo as private when the GitHub API does not show it as public.

## Removing an isolated app

`appmo remove <app>` does these things:

- stops the app
- keeps its `.env` as `/home/appmotel/.config/appmotel/<app>/.env.backup`, which the next `appmo add` of that name restores
- saves the app's backups as one archive in `/home/appmotel/.local/share/appmotel-backups/`
- deletes the user, its home and its sudoers file

## Python versions (uv)

Each app user can have its own Python version. If an app asks for a version, appmotel builds the venv with [uv](https://docs.astral.sh/uv/). uv installs that Python into the app user's home, so no root and no system package is needed. About 90 MB of disk is used for each app that does this.

The version is taken from the first of these that is set:

1. `PYTHON_VERSION=3.12` in the app's `.env`
2. a `.python-version` file in the repo
3. `requires-python` in `pyproject.toml`
4. `PYTHON_VERSION` in appmotel's `.env` (the default for all apps)

If none is set, the system `python3` is used, as before.

To change the version of a deployed app, set `PYTHON_VERSION` in its `.env` and remove the old venv:

```bash
appmo env myapp                       # add PYTHON_VERSION=3.12
appmo exec myapp rm -rf .venv
appmo update myapp
```

## Troubleshooting

```bash
appmo list                                     # USER column shows a-<app> for isolated apps
appmo logs myapp                               # logs of the app user's service
sudo -u appmotel sudo -u a-myapp bash -l       # a shell as the app user (as operator)
sudo -l -U a-myapp                             # must say: not allowed to run sudo
```

- **"Could not create user a-myapp":** `/usr/local/bin/appmotel-user` is missing or old. Run `sudo bash install.sh`.
- **"user a-myapp would get sudo rights":** an old operator rule in `/etc/sudoers.d/appmotel` has no `!%appmotel-apps` exclusion. Run `sudo bash install.sh`.
- **The URL gives 404 for a moment after a deploy:** Traefik loads a new route about a second after it is written. `appmo add` waits for the URL before it ends.
