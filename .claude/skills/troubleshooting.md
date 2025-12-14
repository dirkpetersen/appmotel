---
name: troubleshooting
description: Common Appmotel issues including Traefik 404 errors, certificate permissions, and debugging procedures
---

# Appmotel Troubleshooting Guide

## Traefik Issues

### Issue: 404 Errors Despite Correct Dynamic Configuration

**Symptoms:**
- Dynamic config files are present in `~/.config/traefik/dynamic/`
- App is running and accessible on localhost
- Traefik returns `404 page not found` for HTTPS requests
- Logs show: "Serving default certificate for request: domain"

**Root Causes:**
1. TLS configuration in wrong location (static config instead of dynamic)
2. Router TLS section has incorrect syntax (`tls:` instead of `tls: {}`)

**Solution:**

1. **Move TLS certificate configuration to dynamic config:**

   Create `/home/appmotel/.config/traefik/dynamic/tls-config.yaml`:
   ```yaml
   tls:
     stores:
       default:
         defaultCertificate:
           certFile: /etc/letsencrypt/live/yourdomain.edu/fullchain.pem
           keyFile: /etc/letsencrypt/live/yourdomain.edu/privkey.pem
   ```

2. **Fix router TLS syntax:**

   Change from `tls:` to `tls: {}` in app config files.

3. **Verify:**
   ```bash
   sudo -u appmotel sudo systemctl restart traefik-appmotel
   openssl s_client -connect myapp.domain.edu:443 -servername myapp.domain.edu </dev/null 2>&1 | grep "subject="
   curl https://myapp.domain.edu/
   ```

### Issue: Permission Denied Reading Certificates

**Symptoms:**
- Traefik cannot read `/etc/letsencrypt/live/` certificate files
- Logs show permission errors

**Secure Solution (ssl-cert group):**

```bash
# 1. Ensure ssl-cert group exists
# Debian/Ubuntu:
sudo apt-get install -y ssl-cert
# RHEL/CentOS/Fedora:
sudo groupadd ssl-cert

# 2. Add appmotel to the group
sudo usermod -aG ssl-cert appmotel

# 3. Set group ownership
sudo chgrp -R ssl-cert /etc/letsencrypt/archive
sudo chgrp -R ssl-cert /etc/letsencrypt/live

# 4. Set secure directory permissions (750)
sudo chmod 750 /etc/letsencrypt/{archive,live}
sudo chmod 750 /etc/letsencrypt/archive/*
sudo chmod 750 /etc/letsencrypt/live/*

# 5. Set secure file permissions
# Private keys: 640 (NOT world-readable!)
sudo find /etc/letsencrypt/archive -name "privkey*.pem" -exec chmod 640 {} \;
# Public certs: 644
sudo find /etc/letsencrypt/archive -name "*.pem" ! -name "privkey*.pem" -exec chmod 644 {} \;

# 6. Restart Traefik
sudo -u appmotel sudo systemctl restart traefik-appmotel
```

**Verify access:**
```bash
sudo -u appmotel test -r /etc/letsencrypt/live/yourdomain.edu/fullchain.pem && echo "OK" || echo "FAILED"
sudo -u appmotel test -r /etc/letsencrypt/live/yourdomain.edu/privkey.pem && echo "OK" || echo "FAILED"
```

## Debugging Tools

### Enable Debug Logging

In `/home/appmotel/.config/traefik/traefik.yaml`:
```yaml
log:
  level: DEBUG
```

```bash
sudo -u appmotel sudo systemctl restart traefik-appmotel
sudo journalctl -u traefik-appmotel -f
```

### Check Traefik API

```bash
# List all routers
curl -s http://localhost:8080/api/http/routers | python3 -m json.tool

# Check specific router
curl -s http://localhost:8080/api/http/routers/myapp@file | python3 -m json.tool
```

### Test Components Individually

```bash
# 1. Test app directly
curl http://localhost:8000/

# 2. Test Traefik HTTP (should redirect)
curl -v -H "Host: myapp.domain.edu" http://localhost:80/

# 3. Test Traefik HTTPS
curl -v https://myapp.domain.edu/

# 4. Check certificate
openssl s_client -connect myapp.domain.edu:443 -servername myapp.domain.edu </dev/null 2>&1 | grep -E "(subject=|issuer=)"
```

## Application Issues

### App Service Won't Start

```bash
# Check status
sudo -u appmotel systemctl --user status appmotel-myapp

# View logs
sudo -u appmotel journalctl --user -u appmotel-myapp -n 50
```

**Common causes:**
- Port already in use
- Missing dependencies in `.venv`
- Syntax errors in application code
- Missing environment variables

### Port Conflicts

```bash
# Check what's using a port
ss -tlnp | grep :8000

# Stop service
sudo -u appmotel systemctl --user stop appmotel-myapp
```

## Permission Issues

### Verify Execution Model

```bash
# Test operator → appmotel delegation
sudo -u appmotel whoami
# Expected: appmotel

# Test appmotel → root (limited) delegation
sudo -u appmotel sudo systemctl status traefik-appmotel
# Expected: Shows Traefik service status

# Test that appmotel cannot run arbitrary root commands
sudo -u appmotel sudo whoami
# Expected: FAILS (not in allowed commands)

# Test user-level service management
sudo -u appmotel systemctl --user status
# Expected: Shows user services
```

If any fail, check `/etc/sudoers.d/appmotel`.

## Configuration Validation

### Validate YAML Syntax

```bash
sudo -u appmotel bash -c 'cd ~/.config/traefik/dynamic && for f in *.yaml; do echo "=== $f ==="; python3 -c "import yaml; yaml.safe_load(open(\"$f\"))" && echo "OK" || echo "SYNTAX ERROR"; done'
```

### Verify File Permissions

```bash
ls -la /home/appmotel/.config/traefik/dynamic/
```

## Getting Help

When reporting issues, include:

1. **Service status:**
   ```bash
   sudo -u appmotel sudo systemctl status traefik-appmotel
   sudo -u appmotel systemctl --user status appmotel-myapp
   ```

2. **Recent logs:**
   ```bash
   sudo journalctl -u traefik-appmotel -n 100 --no-pager
   sudo -u appmotel journalctl --user -u appmotel-myapp -n 100 --no-pager
   ```

3. **Configuration files:**
   - `/home/appmotel/.config/traefik/traefik.yaml`
   - `/home/appmotel/.config/traefik/dynamic/*.yaml`
   - App's systemd service file
