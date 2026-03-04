---
name: dns-configuration
description: DNS configuration options and best practices for Appmotel application routing
---

# DNS Configuration for Appmotel

Appmotel assigns each app a subdomain under `BASE_DOMAIN`. For example, `BASE_DOMAIN=apps.yourdomain.edu` makes `myapp` accessible at `myapp.apps.yourdomain.edu`.

## Option 1: AWS Route53 Automatic DNS (Best for AWS)

Use `install-aws.sh` — handles everything automatically:

```bash
bash install-aws.sh [instance-type] [region]  # Default: t4g.micro us-west-2
```

Creates EC2 instance with IAM role, wildcard DNS records (`*.apps.yourdomain.edu`), and DNS-01 wildcard SSL certificates. No AWS credentials on server (uses IAM role).

✅ Fully automatic | ✅ Wildcard certs | ✅ IAM role auth | ⚠️ AWS/Route53 only

## Option 2: Wildcard A Record (Recommended for most)

Single DNS record routes all subdomains:

```dns
*.apps.yourdomain.edu.  IN  A  203.0.113.10
```

✅ New apps work automatically | ✅ Zero maintenance | ✅ All DNS providers

## Option 3: Individual CNAME or A Records (Fallback)

Use only if wildcards aren't supported:

```dns
# A records
myapp.apps.yourdomain.edu.  IN  A  203.0.113.10

# Or CNAME records
myapp.apps.yourdomain.edu.  IN  CNAME  server01.yourdomain.edu.
```

✅ Universal compatibility | ⚠️ Manual update per new app | ⚠️ DNS propagation delay

## Option 4: On-Premises with Route53 DNS-01 (Planned)

> **Status:** Not yet implemented. For servers behind firewalls where port 80 is blocked.

DNS-01 challenge validates via DNS TXT records — works anywhere with outbound HTTPS only. Planned config:

```bash
# ~/.config/appmotel/.env
LETSENCRYPT_MODE="dns"
AWS_HOSTED_ZONE_ID="Z1234567890"
```

Manual workaround: configure Traefik's `traefik.yaml` with Route53 DNS-01 resolver directly.

## Decision Matrix

| Factor | Option 1 (Route53 AWS) | Option 2 (Wildcard) | Option 3 (Individual) | Option 4 (On-Prem) |
|--------|------------------------|---------------------|----------------------|---------------------|
| Auto for new apps | ✅ | ✅ | ❌ | ✅ |
| Setup complexity | 🟢 Scripted | 🟢 Low | 🟡 Medium | 🟡 TBD |
| Port 80 required | ❌ DNS-01 | ✅ | ✅ | ❌ DNS-01 |
| SSL certificates | ✅ Wildcard | 🟡 Per-domain | 🟡 Per-domain | ✅ Wildcard |
| Best for | AWS EC2 | Non-AWS cloud | Small/stable | On-premises |

## Configuration Workflow

```bash
# 1. Set BASE_DOMAIN
echo 'BASE_DOMAIN="apps.yourdomain.edu"' >> ~/.config/appmotel/.env

# 2. Restart Traefik
sudo systemctl restart traefik-appmotel

# 3. Deploy an app
appmo add myapp https://github.com/username/repo main

# 4. Test
dig myapp.apps.yourdomain.edu
curl -v https://myapp.apps.yourdomain.edu
```

**See also:**
- [troubleshooting.md](troubleshooting.md) — DNS not resolving, certificate errors, 404s
- [reference.md](reference.md) — DNS provider notes, best practices
