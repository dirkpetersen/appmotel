---
name: dns-configuration
description: DNS configuration options and best practices for Appmotel application routing
---

# DNS Configuration for Appmotel

This skill covers DNS setup for routing traffic to applications deployed on Appmotel.

## Overview

Appmotel assigns each application a subdomain under `BASE_DOMAIN` (configured in `~/.config/appmotel/.env`). For example, if `BASE_DOMAIN=apps.yourdomain.edu`, then an app named `myapp` becomes accessible at `myapp.apps.yourdomain.edu`.

To make applications reachable, you must configure DNS to route traffic from these subdomains to your Appmotel server.

## DNS Configuration Options

### Option 1: Subdomain Delegation (Best)

**Priority:** 🥇 Best for production deployments

**When to use:**
- You have full control over your parent domain
- You want complete DNS autonomy for app subdomains
- You're willing to run a DNS server on your Appmotel host
- You expect to deploy many applications

**Requirements:**
- A DNS server running on your Appmotel host (CoreDNS, PowerDNS, BIND, etc.)
- Access to modify NS records in parent domain zone
- Static IP address for Appmotel server

**Setup Example:**

1. **Install and configure DNS server on Appmotel host:**
   ```bash
   # Example with CoreDNS
   # Install CoreDNS and configure it to handle *.apps.yourdomain.edu
   ```

2. **Add NS records in parent domain zone:**
   ```dns
   ; Delegate apps.yourdomain.edu to this server
   apps.yourdomain.edu.  IN  NS  ns1.yourdomain.edu.

   ; Point NS hostname to server IP
   ns1.yourdomain.edu.   IN  A   203.0.113.10
   ```

3. **Configure DNS server to answer queries for app subdomains:**
   ```dns
   ; In your DNS server's zone file for apps.yourdomain.edu
   *.apps.yourdomain.edu.  IN  A  203.0.113.10
   ```

**Advantages:**
- ✅ New apps automatically work without DNS updates
- ✅ Complete control over subdomain DNS (A, AAAA, TXT, SRV, etc.)
- ✅ Can implement dynamic DNS updates programmatically
- ✅ Best for large-scale deployments with many apps
- ✅ Can delegate to different IPs per app if needed

**Disadvantages:**
- ⚠️ Requires running and maintaining a DNS server
- ⚠️ More complex initial setup
- ⚠️ DNS server becomes a critical dependency

**Testing:**
```bash
# Verify NS delegation
dig NS apps.yourdomain.edu

# Test subdomain resolution
dig myapp.apps.yourdomain.edu

# Verify it points to correct IP
dig +short myapp.apps.yourdomain.edu
```

---

### Option 2: Wildcard A Record (Recommended)

**Priority:** 🥈 Best for most users

**When to use:**
- You control the DNS zone for your domain
- Your DNS provider supports wildcard records
- You want a simple, zero-maintenance solution
- All apps will run on the same server IP

**Requirements:**
- Access to DNS zone management for your domain
- DNS provider that supports wildcard records (most do)

**Setup Example:**

Add a single wildcard A record in your DNS zone:

```dns
*.apps.yourdomain.edu.  IN  A  203.0.113.10
```

This single record routes ALL subdomains under `apps.yourdomain.edu` to your Appmotel server.

**Advantages:**
- ✅ New apps automatically work without DNS updates
- ✅ Extremely simple (single DNS record)
- ✅ No additional software required
- ✅ Best for most use cases
- ✅ Works with all standard DNS providers

**Disadvantages:**
- ⚠️ Not all DNS providers support wildcards (rare)
- ⚠️ All subdomains point to same IP (can't split apps across servers)
- ⚠️ Less granular control than subdomain delegation

**Testing:**
```bash
# Test wildcard resolution
dig myapp.apps.yourdomain.edu
dig another-app.apps.yourdomain.edu
dig any-subdomain.apps.yourdomain.edu

# All should return 203.0.113.10
```

---

### Option 3: Individual CNAME or A Records (Fallback)

**Priority:** 🥉 Use only if wildcards aren't supported

**When to use:**
- Your DNS provider doesn't support wildcard records
- You need explicit control over each subdomain
- You have a small, stable number of apps
- You want to point different apps to different servers

**Requirements:**
- Access to DNS zone management
- Willingness to manually update DNS for each new app

**Setup Example:**

**Option 3a: Individual A Records**
```dns
myapp.apps.yourdomain.edu.      IN  A  203.0.113.10
api.apps.yourdomain.edu.        IN  A  203.0.113.10
dashboard.apps.yourdomain.edu.  IN  A  203.0.113.10
```

**Option 3b: Individual CNAME Records**
```dns
myapp.apps.yourdomain.edu.      IN  CNAME  server01.yourdomain.edu.
api.apps.yourdomain.edu.        IN  CNAME  server01.yourdomain.edu.
dashboard.apps.yourdomain.edu.  IN  CNAME  server01.yourdomain.edu.
```

**When to use A records vs CNAME:**
- **A record:** Points directly to an IP address. Use when you have a static IP.
- **CNAME record:** Points to another hostname. Use when your server IP might change or you want to reference an existing hostname.

**Advantages:**
- ✅ Works with ALL DNS providers (universal compatibility)
- ✅ Explicit control over each app's DNS
- ✅ Can point different apps to different servers/IPs
- ✅ Clear visibility of all configured apps in DNS

**Disadvantages:**
- ⚠️ Requires manual DNS update for EVERY new app
- ⚠️ Increased maintenance overhead
- ⚠️ DNS propagation delay (TTL) for new apps
- ⚠️ Human error risk (forgetting to add DNS)

**Testing:**
```bash
# Test each configured subdomain
dig myapp.apps.yourdomain.edu
dig api.apps.yourdomain.edu

# Verify they point to correct destination
dig +short myapp.apps.yourdomain.edu
```

---

## Decision Matrix

| Factor | Option 1 (NS) | Option 2 (Wildcard) | Option 3 (Individual) |
|--------|---------------|---------------------|----------------------|
| **Automatic for new apps** | ✅ Yes | ✅ Yes | ❌ No |
| **Setup complexity** | 🔴 High | 🟢 Low | 🟡 Medium |
| **Maintenance required** | 🟡 DNS server | 🟢 None | 🔴 Per app |
| **DNS provider requirements** | None | Wildcard support | None |
| **Flexibility** | 🟢 Maximum | 🟡 Limited | 🟢 High |
| **Best for** | Large/production | Most users | Small/stable |

## Configuration Workflow

### Step 1: Set BASE_DOMAIN

Edit `~/.config/appmotel/.env`:
```bash
BASE_DOMAIN="apps.yourdomain.edu"
```

### Step 2: Restart Traefik
```bash
sudo systemctl restart traefik-appmotel
```

### Step 3: Configure DNS

Choose one of the three options above and configure your DNS accordingly.

### Step 4: Deploy an App

```bash
appmo add myapp https://github.com/username/repo main
```

Appmotel will display DNS configuration guidance specific to your setup.

### Step 5: Test DNS and Connectivity

```bash
# Test DNS resolution
dig myapp.apps.yourdomain.edu

# Test HTTP (should redirect to HTTPS)
curl -v http://myapp.apps.yourdomain.edu

# Test HTTPS
curl -v https://myapp.apps.yourdomain.edu

# Check certificate
openssl s_client -connect myapp.apps.yourdomain.edu:443 \
  -servername myapp.apps.yourdomain.edu </dev/null 2>&1 | \
  grep "subject="
```

## Common Issues

### Issue: DNS not resolving

**Symptoms:**
```bash
$ dig myapp.apps.yourdomain.edu
; <<>> DiG 9.18.24 <<>> myapp.apps.yourdomain.edu
;; ANSWER SECTION:
; (empty)
```

**Solutions:**
1. **Wait for DNS propagation** (TTL expiry, typically 5-60 minutes)
2. **Verify DNS records in provider's control panel**
3. **Check for typos in domain names**
4. **Test with authoritative nameserver directly:**
   ```bash
   dig @8.8.8.8 myapp.apps.yourdomain.edu
   dig @ns1.your-dns-provider.com myapp.apps.yourdomain.edu
   ```

### Issue: Certificate errors (HTTPS fails)

**Symptoms:**
- Browser shows "Certificate not valid for this domain"
- `curl` shows SSL errors

**Solutions:**
1. **Ensure DNS is resolving FIRST** - Let's Encrypt requires working DNS
2. **Check Traefik logs:**
   ```bash
   sudo journalctl -u traefik-appmotel -f | grep -i "certificate\|acme"
   ```
3. **Verify Let's Encrypt configuration in `~/.config/appmotel/.env`:**
   ```bash
   USE_LETSENCRYPT="yes"
   LETSENCRYPT_EMAIL="admin@yourdomain.edu"
   LETSENCRYPT_MODE="http"  # or "dns"
   ```
4. **Check ACME storage permissions:**
   ```bash
   ls -la ~/.local/share/traefik/acme.json
   # Should be: -rw------- (mode 600)
   ```

### Issue: 404 errors on HTTPS

**Symptoms:**
- HTTPS works, certificate is valid
- But Traefik returns "404 page not found"

**Solutions:**
1. **Verify app is running:**
   ```bash
   appmo status myapp
   systemctl --user status appmotel-myapp
   ```
2. **Check Traefik dynamic config:**
   ```bash
   cat ~/.config/traefik/dynamic/myapp.yaml
   # Verify Host() rule matches your domain
   ```
3. **Test app directly on its port:**
   ```bash
   # Get app port from metadata
   cat ~/.config/appmotel/apps/myapp/metadata.env | grep PORT

   # Test directly
   curl http://localhost:8000/
   ```
4. **Check Traefik logs for routing issues:**
   ```bash
   sudo journalctl -u traefik-appmotel -f | grep myapp
   ```

## DNS Provider-Specific Notes

### AWS Route53
- ✅ Supports wildcard records
- ✅ Supports subdomain delegation (NS records)
- 💡 Can use DNS-01 challenge for Let's Encrypt wildcard certificates

### Cloudflare
- ✅ Supports wildcard records
- ✅ Supports subdomain delegation (NS records)
- ⚠️ Proxied records (orange cloud) may interfere with Let's Encrypt HTTP-01
- 💡 Use DNS-01 challenge or disable proxy for ACME validation

### Google Cloud DNS
- ✅ Supports wildcard records
- ✅ Supports subdomain delegation
- 💡 Excellent for programmatic DNS management

### GoDaddy / Namecheap / Basic Providers
- ✅ Most support wildcard records
- ⚠️ Check provider documentation for wildcard syntax
- 💡 Wildcard record is usually entered as `*` in subdomain field

## Best Practices

1. **Use descriptive BASE_DOMAIN names:**
   - ✅ Good: `apps.yourdomain.edu`, `services.company.com`
   - ❌ Bad: `a.yourdomain.edu`, `x.company.com`

2. **Set appropriate DNS TTL:**
   - During testing: Low TTL (300 seconds)
   - In production: Standard TTL (3600-14400 seconds)

3. **Document your DNS configuration:**
   - Record which option you're using
   - Note any special DNS provider requirements
   - Keep credentials secure (for DNS-01 challenges)

4. **Monitor DNS health:**
   - Set up monitoring for DNS resolution
   - Alert on certificate expiration
   - Test new apps in staging first

5. **Security considerations:**
   - Use DNS-01 challenge for wildcard Let's Encrypt certificates (more secure)
   - Restrict DNS server access (if using Option 1)
   - Enable DNSSEC if your provider supports it

## Related Files

- **Traefik configuration:** `~/.config/traefik/traefik.yaml`
- **App-specific routing:** `~/.config/traefik/dynamic/<app-name>.yaml`
- **Appmotel config:** `~/.config/appmotel/.env`
- **Traefik logs:** `sudo journalctl -u traefik-appmotel`
- **App logs:** `appmo logs <app-name>`
