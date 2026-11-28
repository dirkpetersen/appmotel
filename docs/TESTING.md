# Appmotel Testing Guide

This document provides instructions for testing the Appmotel system.

## Prerequisites

- System with sudo access
- Git installed
- Python 3 installed
- Node.js and npm installed
- GitHub account

## Installation Testing

### 1. Clean Installation Test

```bash
# Clean the appmotel user's home directory
cd /path/to/appmotel
sudo -u appmotel bash bin/reset-home.sh --force

# Run installation
sudo bash install.sh
```

**Expected Results:**
- Appmotel user created (if didn't exist)
- Traefik binary downloaded to `/home/appmotel/.local/bin/traefik`
- Directory structure created:
  - `/home/appmotel/.config/traefik/`
  - `/home/appmotel/.config/traefik/dynamic/`
  - `/home/appmotel/.config/appmotel/apps/`
  - `/home/appmotel/.local/share/traefik/`
  - `/home/appmotel/.local/share/appmotel/`
- Traefik configuration generated
- Systemd service `traefik-appmotel` created and running
- Sudoers rules configured
- `appmo` CLI installed to `/usr/local/bin/appmo`

**Verification:**
```bash
# Check Traefik service
systemctl status traefik-appmotel

# Check if appmo is installed
which appmo
appmo --help

# Check Traefik binary
ls -l /home/appmotel/.local/bin/traefik

# Check directory structure (as appmotel user)
sudo su - appmotel
ls -la ~/.config/
ls -la ~/.local/share/
```

### 2. Idempotency Test

Run the installation script again:

```bash
sudo bash install.sh
```

**Expected Results:**
- Script completes without errors
- No duplicate users, services, or configurations created
- Traefik continues running without interruption

## Application Deployment Testing

### Test 1: Python Flask Application

#### Setup Test Repository

```bash
cd examples/flask-hello

# Initialize git repository
git init
git add .
git commit -m "Initial Flask app"

# Create GitHub repository and push
# (Replace with your GitHub username)
gh repo create test-flask-hello --public --source=. --remote=origin --push
```

#### Deploy Application

```bash
appmo add flask-hello https://github.com/<username>/test-flask-hello main
```

**Expected Results:**
- Repository cloned to `/home/appmotel/.local/share/appmotel/flask-hello/repo/`
- Python virtual environment created at `.venv/`
- Dependencies installed from `requirements.txt`
- `install.sh` executed successfully
- Port assigned (8000 or auto-assigned)
- Systemd service `appmotel-flask-hello` created and started
- Traefik config created at `/home/appmotel/.config/traefik/dynamic/flask-hello.yaml`
- App accessible at `https://flask-hello.<BASE_DOMAIN>`

**Verification:**
```bash
# Check service status
appmo status flask-hello

# View logs
appmo logs flask-hello

# Test port
curl http://localhost:8000

# Test via Traefik (if DNS configured)
curl https://flask-hello.<BASE_DOMAIN>
```

### Test 2: Node.js Express Application

#### Setup Test Repository

```bash
cd examples/express-hello

# Initialize git repository
git init
git add .
git commit -m "Initial Express app"

# Create GitHub repository and push
gh repo create test-express-hello --public --source=. --remote=origin --push
```

#### Deploy Application

```bash
appmo add express-hello https://github.com/<username>/test-express-hello main
```

**Expected Results:**
- Repository cloned
- `npm install` executed
- Dependencies installed from `package.json`
- Service created and started
- App accessible at configured port

**Verification:**
```bash
appmo status express-hello
appmo logs express-hello
curl http://localhost:8001
```

## CLI Commands Testing

### List Applications

```bash
appmo list
```

**Expected Output:**
```
APP NAME             STATUS     URL
--------             ------     ---
express-hello        running    https://express-hello.apps.local
flask-hello          running    https://flask-hello.apps.local
```

### Status Checks

```bash
# Single app status
appmo status flask-hello

# All apps status
appmo status
```

**Expected Output:**
- App name and URL
- GitHub repository and branch
- Port number
- Last deployment timestamp
- Systemd service status (running/stopped)
- Port response status

### Service Management

```bash
# Stop application
appmo stop flask-hello
systemctl is-active appmotel-flask-hello  # Should return "inactive"

# Start application
appmo start flask-hello
systemctl is-active appmotel-flask-hello  # Should return "active"

# Restart application
appmo restart flask-hello
```

### Update Application

```bash
# Make changes to the application
cd /path/to/local/test-flask-hello
echo "# Updated" >> README.md
git commit -am "Update app"
git push

# Trigger update
appmo update flask-hello
```

**Expected Results:**
- Latest code pulled from GitHub
- `install.sh` executed
- Python/Node.js dependencies reinstalled
- Service restarted
- Metadata timestamp updated

### View Logs

```bash
# Last 50 lines (default)
appmo logs flask-hello

# Custom number of lines
appmo logs flask-hello 100

# Follow logs in real-time
journalctl -u appmotel-flask-hello -f
```

### Execute Commands

```bash
# Python app
appmo exec flask-hello python3 --version
appmo exec flask-hello pip list

# Node.js app
appmo exec express-hello node --version
appmo exec express-hello npm list
```

### Remove Application

```bash
appmo remove flask-hello
```

**Expected Results:**
- Systemd service stopped and disabled
- Service file deleted
- Traefik config deleted
- App directory removed from `/home/appmotel/.local/share/appmotel/`
- App config removed from `/home/appmotel/.config/appmotel/apps/`

**Verification:**
```bash
# Service should not exist
systemctl status appmotel-flask-hello  # Should fail

# Files should be gone
ls /home/appmotel/.local/share/appmotel/  # flask-hello should not appear
ls /home/appmotel/.config/appmotel/apps/  # flask-hello should not appear

# Should not appear in list
appmo list
```

## Operations Features Testing

Run these with one normal and one isolated app (`appmo add --isolated`). `bash tests/test-appmo.sh` covers the parsing and file generation; these steps cover the parts that need a real host.

### Rollback and Pin

```bash
appmo backups flask-hello                 # COMMIT column is filled
# push a commit that breaks the app, wait for autopull (or appmo update flask-hello)
appmo rollback flask-hello                # back to the commit before the push
appmo status flask-hello                  # "Pinned: rolled back to <commit>"
journalctl --user -u appmotel-autopull -n 5   # "... (1 pinned by rollback, not updated)"
appmo backups flask-hello                 # a new backup of the broken state (undo with appmo restore)
appmo unpin flask-hello                   # next autopull deploys the branch again
```

**Expected:** the app runs the old commit and autopull does not touch it until `unpin`. A second `appmo rollback` goes one version further back. `appmo update` also removes the pin.

### Scheduled Jobs

```bash
# in the app repo
printf '*:0/2 | date >> /tmp/job-test.log\nbogus | true\n' > examples/flask-hello/appmo-schedule
# push, then wait for autopull
appmo status flask-hello                  # "Scheduled jobs": 1 timer, next run in < 2 min
appmo logs flask-hello --grep 'scheduled job'   # the timer ran it
appmo stop flask-hello                    # timer stops too; appmo start resumes it
```

**Expected:** the `bogus` line is skipped with a WARN at deploy time. Removing the file and pushing removes the timer; `appmo remove` removes it too.

### Restart Limit and Crash Loop

```bash
appmo env flask-hello set RESTART_LIMIT 3
appmo restart flask-hello                 # writes appmotel-flask-hello.service.d/restart-limit.conf
# push a commit whose app exits at start (raise SystemExit(1) at the top of app.py), wait for autopull
sleep 60; appmo status flask-hello        # "FAILED: crash loop, systemd stopped restarting it"
# next autopull run: ERROR "flask-hello: crash loop ..." (and a webhook message if set)
appmo rollback flask-hello                # running again on the good commit
appmo env flask-hello unset RESTART_LIMIT; appmo restart flask-hello   # drop-in removed
```

Without `RESTART_LIMIT`, `appmo status` shows `CRASHED, systemd restarts it` and autopull still reports the crash loop (3+ restarts between two runs).

### Logs, Top, Backup Verify, Certificates, Notifications

```bash
appmo logs flask-hello --since "10 min ago"
appmo logs flask-hello --grep 'GET /' 5   # last 5 matching lines
appmo top                                 # one row per app, isolated apps included
appmo backup-verify flask-hello           # all "ok"
appmo certs                               # with USE_LETSENCRYPT=yes: one row per app certificate
appmo env flask-hello set NOTIFY_WEBHOOK_URL https://<your test webhook>
appmo update flask-hello                  # the webhook gets "deployed main <old> -> <new>"
```

## Error Handling Tests

### Test 1: Invalid App Name

```bash
appmo add "my app" https://github.com/user/repo main
```

**Expected:** Error message about invalid app name format

### Test 2: Duplicate App Name

```bash
appmo add express-hello https://github.com/user/repo main
```

**Expected:** Error message that app already exists

### Test 3: Invalid GitHub URL

```bash
appmo add testapp https://github.com/nonexistent/repo main
```

**Expected:** Clone fails, operation rolls back, no app created

### Test 4: Failed install.sh

Create an app with a failing install.sh:

```bash
echo '#!/bin/bash' > /tmp/test-fail/install.sh
echo 'exit 1' >> /tmp/test-fail/install.sh
# Create git repo and try to add
```

**Expected:** Installation fails, operation rolls back, app not created

### Test 5: Port Already in Use

```bash
# Start a process on port 8000
python3 -m http.server 8000 &
SERVER_PID=$!

# Try to add app configured for port 8000
# Expected: Error about port in use

# Cleanup
kill $SERVER_PID
```

## Traefik Configuration Tests

### Verify Dynamic Config

```bash
# Check Traefik config files
sudo su - appmotel
cat ~/.config/traefik/traefik.yaml
ls -l ~/.config/traefik/dynamic/
cat ~/.config/traefik/dynamic/flask-hello.yaml
```

**Expected:**
- Static config correctly references dynamic directory
- Dynamic configs created for each app
- Correct routing rules (Host, entryPoints, TLS)
- Correct service URLs (localhost:PORT)

### Test Traefik Reload

```bash
# Add new app
appmo add testapp3 <repo> main

# Traefik should automatically pick up new config
# Check Traefik logs
journalctl -u traefik-appmotel -n 50
```

**Expected:** Traefik logs show configuration reload without restart

## Performance Tests

### Multiple App Deployment

Deploy 5 apps simultaneously:

```bash
for i in {1..5}; do
  appmo add testapp$i <repo> main &
done
wait
```

**Expected:**
- All apps deploy successfully
- No port conflicts
- All services running
- Traefik routing all apps correctly

## Security Tests

### File Permissions

```bash
# Check ACME file permissions
ls -l /home/appmotel/.local/share/traefik/acme.json
# Expected: 600 (-rw-------)

# Check config directory ownership
ls -ld /home/appmotel/.config/traefik/
# Expected: owned by appmotel:appmotel
```

### Sudoers Configuration

```bash
# As appmotel user, verify allowed commands
sudo su - appmotel
sudo systemctl restart traefik-appmotel  # Should work
sudo systemctl restart appmotel-flask-hello  # Should work
sudo apt-get update  # Should fail (not allowed)
```

## Cleanup After Testing

```bash
# Remove all test apps
appmo list | tail -n +3 | awk '{print $1}' | xargs -I {} appmo remove {}

# Or clean everything
sudo su - appmotel
rm -rf /home/appmotel/*
rm -rf /home/appmotel/.[^.]*
exit

# Remove systemd services
sudo rm /etc/systemd/system/appmotel-*.service
sudo rm /etc/systemd/system/traefik-appmotel.service
sudo systemctl daemon-reload

# Remove appmo CLI
sudo rm /usr/local/bin/appmo

# Delete test repositories from GitHub
gh repo delete test-flask-hello --yes
gh repo delete test-express-hello --yes
```

## Troubleshooting

### Service Won't Start

```bash
# Check service status
systemctl status appmotel-<app-name>

# Check journalctl logs
journalctl -u appmotel-<app-name> -n 100

# Check app's install.sh output
# Check if dependencies are installed
```

### Port Not Responding

```bash
# Check if port is in use
ss -tuln | grep <PORT>

# Check app logs
appmo logs <app-name>

# Try to connect directly
curl http://localhost:<PORT>
```

### Traefik Issues

```bash
# Check Traefik status
systemctl status traefik-appmotel

# Check Traefik logs
journalctl -u traefik-appmotel -n 100

# Verify Traefik config syntax
/home/appmotel/.local/bin/traefik validate --configFile=/home/appmotel/.config/traefik/traefik.yaml
```

## Test Checklist

- [ ] Clean installation completes successfully
- [ ] Installation is idempotent
- [ ] Python Flask app deploys correctly
- [ ] Node.js Express app deploys correctly
- [ ] `appmo list` shows all apps
- [ ] `appmo status` shows correct information
- [ ] `appmo start/stop/restart` work correctly
- [ ] `appmo update` pulls and reinstalls correctly
- [ ] `appmo logs` displays application logs
- [ ] `appmo exec` runs commands in app environment
- [ ] `appmo remove` cleanly removes apps
- [ ] `appmo rollback` restores the previous commit and pins; `unpin`/`update` release it
- [ ] `appmo-schedule` lines become timers; bad lines are skipped; stop/start/remove handle them
- [ ] A crash loop shows in `appmo status` and is reported by autopull
- [ ] `appmo logs --since/--grep`, `appmo top`, `appmo backup-verify`, `appmo certs` work for normal and isolated apps
- [ ] Error handling works for invalid inputs
- [ ] Port assignment works correctly
- [ ] Traefik routes traffic correctly
- [ ] Multiple apps can run simultaneously
- [ ] File permissions are correct
- [ ] Sudoers configuration works as expected
