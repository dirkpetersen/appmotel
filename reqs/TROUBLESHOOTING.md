# Troubleshooting Guide

This document covers common issues and their solutions for Appmotel.

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

2. **Fix router TLS syntax in app config files:**

   Change from:
   ```yaml
   http:
     routers:
       myapp:
         rule: "Host(`myapp.domain.edu`)"
         entryPoints:
           - websecure
         service: myapp
         tls:  # WRONG - null/empty
   ```

   To:
   ```yaml
   http:
     routers:
       myapp:
         rule: "Host(`myapp.domain.edu`)"
         entryPoints:
           - websecure
         service: myapp
         tls: {}  # CORRECT - empty object
   ```

3. **Verify changes:**
   ```bash
   # Traefik auto-reloads, but you can restart to be sure
   sudo -u appmotel sudo systemctl restart traefik-appmotel

   # Check the certificate
   openssl s_client -connect myapp.domain.edu:443 -servername myapp.domain.edu </dev/null 2>&1 | grep "subject="

   # Test the app
   curl https://myapp.domain.edu/
   ```

**Why This Happens:**
In Traefik v3, TLS certificate stores MUST be defined in dynamic configuration, not static configuration. Additionally, an empty `tls:` (null value) does not properly enable TLS termination - it must be an empty object `tls: {}`.

### Issue: Permission Denied Reading Certificates

**Symptoms:**
- Traefik cannot read `/etc/letsencrypt/live/` certificate files
- Logs show permission errors
- Certificate files are world-readable (security issue!)

**Secure Solution (Recommended):**

Use the `ssl-cert` group approach (already implemented in install.sh).

**Background:** This follows the Debian/Ubuntu convention where the `ssl-cert` package provides a dedicated group for secure certificate access. On RHEL/CentOS/Fedora, this package doesn't exist, so the group must be created manually.

```bash
# 1. Ensure ssl-cert group exists
# On Debian/Ubuntu (recommended - also creates /etc/ssl/private):
sudo apt-get install -y ssl-cert

# On RHEL/CentOS/Fedora (or if package installation fails):
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

# 6. Restart Traefik to apply group membership
sudo -u appmotel sudo systemctl restart traefik-appmotel
```

**Alternative (Less secure, not recommended):**
```bash
# Using ACLs
sudo setfacl -R -m u:appmotel:rx /etc/letsencrypt/live/
sudo setfacl -R -m u:appmotel:rx /etc/letsencrypt/archive/
```

**Security Note:**
Never use `chmod 644` or `chmod 744` on private keys! This makes them readable by all users on the system. Always use `640` for private keys with group-based access.

Verify access:
```bash
sudo -u appmotel test -r /etc/letsencrypt/live/yourdomain.edu/fullchain.pem && echo "OK" || echo "FAILED"
sudo -u appmotel test -r /etc/letsencrypt/live/yourdomain.edu/privkey.pem && echo "OK" || echo "FAILED"
```

## Debugging Tools

### Enable Debug Logging

Temporarily enable debug logging in `/home/appmotel/.config/traefik/traefik.yaml`:
```yaml
log:
  level: DEBUG
```

Restart Traefik and watch logs:
```bash
sudo -u appmotel sudo systemctl restart traefik-appmotel
sudo journalctl -u traefik-appmotel -f
```

Remember to set back to `INFO` after debugging.

### Check Traefik API

Enable the dashboard in static config:
```yaml
api:
  dashboard: true
  insecure: true  # Only for debugging on localhost
```

Query the API:
```bash
# List all routers
curl -s http://localhost:8080/api/http/routers | python3 -m json.tool

# Check specific router
curl -s http://localhost:8080/api/http/routers/myapp@file | python3 -m json.tool

# Check services
curl -s http://localhost:8080/api/http/services/myapp@file | python3 -m json.tool
```

### Test Components Individually

1. **Test app directly:**
   ```bash
   curl http://localhost:8000/
   ```

2. **Test Traefik HTTP (should redirect):**
   ```bash
   curl -v -H "Host: myapp.domain.edu" http://localhost:80/
   ```

3. **Test Traefik HTTPS:**
   ```bash
   curl -v https://myapp.domain.edu/
   ```

4. **Check certificate being served:**
   ```bash
   openssl s_client -connect myapp.domain.edu:443 -servername myapp.domain.edu </dev/null 2>&1 | grep -E "(subject=|issuer=)"
   ```

## Application Issues

### App Service Won't Start

**Check service status:**
```bash
sudo -u appmotel systemctl --user status appmotel-myapp
```

**View logs:**
```bash
sudo -u appmotel journalctl --user -u appmotel-myapp -n 50
```

**Common causes:**
- Port already in use
- Missing dependencies in `.venv`
- Syntax errors in application code
- Missing environment variables

### Port Conflicts

**Check what's using a port:**
```bash
ss -tlnp | grep :8000
```

**Kill process (if needed):**
```bash
sudo -u appmotel systemctl --user stop appmotel-myapp
```

## Permission Issues

### Verify Execution Model

Test the three-tier permission model:

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

If any of these fail, check `/etc/sudoers.d/appmotel`.

## Configuration Validation

### Validate YAML Syntax

```bash
# Check all dynamic configs
sudo -u appmotel bash -c 'cd ~/.config/traefik/dynamic && for f in *.yaml; do echo "=== $f ==="; python3 -c "import yaml; yaml.safe_load(open(\"$f\"))" && echo "OK" || echo "SYNTAX ERROR"; done'
```

### Verify File Permissions

```bash
# Check dynamic config files
ls -la /home/appmotel/.config/traefik/dynamic/

# All files should be readable by appmotel user
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

4. **Test results from debugging tools above**
