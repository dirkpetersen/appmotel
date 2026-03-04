# DNS Reference

## Provider Notes

| Provider | Wildcard | Notes |
|----------|----------|-------|
| **AWS Route53** | ✅ | Best choice — use `install-aws.sh` for full automation with IAM role auth |
| **Cloudflare** | ✅ | Proxied (orange cloud) may interfere with HTTP-01; use DNS-01 or disable proxy for ACME |
| **Google Cloud DNS** | ✅ | Excellent for programmatic DNS management |
| **GoDaddy / Namecheap** | ✅ | Enter wildcard as `*` in the subdomain field |

## Best Practices

1. **Use descriptive BASE_DOMAIN names:** `apps.yourdomain.edu`, `services.company.com` (not `a.x.com`)

2. **Set appropriate TTL:**
   - Testing: 300 seconds
   - Production: 3600–14400 seconds

3. **Security:**
   - Use DNS-01 challenge for wildcard Let's Encrypt certificates
   - Use IAM roles instead of stored credentials (AWS Route53)
   - Enable DNSSEC if your provider supports it

4. **Related files:**
   - Traefik config: `~/.config/traefik/traefik.yaml`
   - Per-app routing: `~/.config/traefik/dynamic/<app-name>.yaml`
   - Appmotel config: `~/.config/appmotel/.env`
