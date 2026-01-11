# Environment Variable Management

This guide explains how Appmotel manages `.env` files for application configuration.

## Storage Location

Physical `.env` files are stored in the **config directory**, NOT in the repository:

```
~/.config/appmotel/<app>/.env  # Physical file (persistent)
~/.local/share/appmotel/<app>/repo/.env  # Symlink to config file
```

This separation provides several benefits:

1. **Persistent configuration** across app reinstalls and updates
2. **Security** - Secrets never committed to git
3. **Backup/restore workflow** - Configuration survives app removal
4. **Version control independence** - Configuration changes don't affect git status

## File Lifecycle

### 1. Initial Deployment

When you deploy an app with `appmo add`:

```bash
sudo -u appmotel appmo add myapp https://github.com/username/repo main
```

Appmotel:
1. Clones the repository to `~/.local/share/appmotel/myapp/repo/`
2. Checks for `.env` in the repo (used as template)
3. Creates physical `.env` in `~/.config/appmotel/myapp/.env`
4. Creates symlink from repo to config: `repo/.env -> ~/.config/appmotel/myapp/.env`
5. Assigns PORT if not specified (auto-assigned from 10001-59999)

### 2. Editing Configuration

Edit the `.env` file using the `appmo env` command:

```bash
sudo -u appmotel appmo env myapp
```

This opens the **physical file** in `~/.config/appmotel/myapp/.env` using your default editor (`$EDITOR` or `nano`).

**After editing, restart the app:**
```bash
sudo -u appmotel appmo restart myapp
```

### 3. Backup on Removal

When you remove an app with `appmo remove`:

```bash
sudo -u appmotel appmo remove myapp
```

Appmotel:
1. Stops all services for the app
2. **Backs up** `.env` to `.env.backup` in the same directory
3. Removes all services, configs, and repo
4. Preserves the backup for future restoration

### 4. Restore on Re-add

When re-adding a previously removed app:

```bash
sudo -u appmotel appmo add myapp https://github.com/username/repo main
```

Appmotel detects the existing `.env.backup` and prompts:

```
Found previous .env backup for 'myapp'
Would you like to restore it? (y/n):
```

- **Yes**: Restores the previous `.env` configuration
- **No**: Creates fresh `.env` from repo template or defaults

## Port Variable Detection

Appmotel supports multiple port variable names with priority order:

### Priority Order

1. **`PORT`** (highest priority)
2. **`FLASK_PORT`** (for Flask apps)
3. **Any `*PORT*` variable** (e.g., `NODE_PORT`, `SERVER_PORT`)

### Reading Ports

```bash
# Example .env file
PORT=8000
FLASK_PORT=8000
```

Appmotel reads ports using this logic:
```bash
get_port_from_env() {
  # 1. Try PORT first
  port=$(grep -E '^PORT=' .env | cut -d'=' -f2)

  # 2. Fall back to FLASK_PORT
  port=$(grep -E '^FLASK_PORT=' .env | cut -d'=' -f2)

  # 3. Fall back to any *PORT* variable
  port=$(grep -iE '^[A-Z_]*PORT[A-Z_]*=' .env | cut -d'=' -f2)
}
```

### Updating Ports

When Appmotel assigns or updates ports, it updates **both** `PORT` and `FLASK_PORT` if they exist:

```bash
# Before
PORT=5000
FLASK_PORT=5000

# After appmo assigns port 8123
PORT=8123
FLASK_PORT=8123
```

## Required Variables

### Mandatory

- **`PORT`** - Application listen port (10001-59999)
  - Auto-assigned if not specified
  - Must be unique per app

### Optional Configuration

#### Resource Limits
```bash
MEMORY_LIMIT=512M    # Default: 512M
CPU_QUOTA=100%       # Default: 100% (one full core)
```

#### Rate Limiting
```bash
RATE_LIMIT_AVG=100         # Requests/sec average (default: 100)
RATE_LIMIT_BURST=50        # Burst requests (default: 50)
DISABLE_RATE_LIMIT=true    # Disable rate limiting (optional)
```

#### Health Checks
```bash
HEALTH_CHECK_PATH=/health  # Health endpoint path (default: /health)
```

#### Application Variables
```bash
APP_NAME="My Application"
DATABASE_URL="postgresql://..."
API_KEY="secret-key-here"
DEBUG=false
```

## Example Configurations

### Python Flask App

**~/.config/appmotel/flask-app/.env:**
```bash
PORT=8000
FLASK_APP=app.py
FLASK_ENV=production
DATABASE_URL=postgresql://localhost/mydb
SECRET_KEY=your-secret-key-here
MEMORY_LIMIT=1G
RATE_LIMIT_AVG=200
```

### Node.js Express App

**~/.config/appmotel/express-app/.env:**
```bash
PORT=8001
NODE_ENV=production
DATABASE_URL=postgresql://localhost/mydb
JWT_SECRET=your-jwt-secret
MEMORY_LIMIT=512M
CPU_QUOTA=100%
```

### Go Application

**~/.config/appmotel/go-app/.env:**
```bash
PORT=8002
DATABASE_URL=postgresql://localhost/mydb
API_KEY=your-api-key
LOG_LEVEL=info
MEMORY_LIMIT=256M
```

### Multi-Component App

**~/.config/appmotel/fullstack-app/.env:**
```bash
# Frontend gets main PORT
PORT=8000

# Backend gets internal port (auto-assigned)
BACKEND_PORT=8001

# Shared configuration
DATABASE_URL=postgresql://localhost/mydb
REDIS_URL=redis://localhost:6379
API_KEY=shared-api-key

# Resource limits (apply to all components)
MEMORY_LIMIT=512M
CPU_QUOTA=100%
```

## Direct File Access

You can also directly read/edit the `.env` file:

### Reading
```bash
# Read the physical file
cat ~/.config/appmotel/myapp/.env

# Or via the symlink in repo
cat ~/.local/share/appmotel/myapp/repo/.env
```

### Writing
```bash
# From apps user (operator account)
# Use sudo -u appmotel
sudo -u appmotel bash -c 'echo "NEW_VAR=value" >> ~/.config/appmotel/myapp/.env'

# From appmotel user
echo "NEW_VAR=value" >> ~/.config/appmotel/myapp/.env
```

**Note**: Always restart the app after modifying `.env`:
```bash
sudo -u appmotel appmo restart myapp
```

## Environment Variable Precedence

When an app runs, environment variables come from these sources (highest to lowest priority):

1. **Systemd service `Environment=` directives** (e.g., `PORT`)
2. **`.env` file** in app's config directory
3. **System environment** (inherited from systemd user session)
4. **Application defaults** (hardcoded in app code)

Appmotel injects critical variables directly into the systemd service:
```ini
[Service]
Environment="PORT=8000"
EnvironmentFile=%h/.config/appmotel/myapp/.env
```

This ensures `PORT` is always available, even if `.env` is missing.

## Security Best Practices

### 1. Never Commit Secrets

**❌ WRONG**: Committing `.env` to git
```bash
# .gitignore should contain:
.env
.env.local
.env.*.local
```

**✅ CORRECT**: Keep secrets in Appmotel config only
```bash
# Physical file only in ~/.config/appmotel/<app>/.env
# Symlink in repo points to it (never committed)
```

### 2. Use Strong Secrets

Generate secure random secrets:
```bash
# Generate random secret
openssl rand -hex 32

# Add to .env
sudo -u appmotel appmo env myapp
# Then add: SECRET_KEY=<generated-value>
```

### 3. Restrict File Permissions

Appmotel automatically sets correct permissions:
```bash
# Config directory: 700 (owner only)
chmod 700 ~/.config/appmotel/myapp/

# .env file: 600 (owner read/write only)
chmod 600 ~/.config/appmotel/myapp/.env
```

### 4. Backup Sensitive Configuration

Create manual backups of important configuration:
```bash
# Backup all app configs
sudo -u appmotel appmo backup myapp

# Or manually
sudo -u appmotel tar -czf ~/myapp-env-backup.tar.gz ~/.config/appmotel/myapp/.env
```

## Troubleshooting

### App Not Reading Environment Variables

**Check if .env exists:**
```bash
ls -la ~/.config/appmotel/myapp/.env
```

**Verify symlink:**
```bash
ls -la ~/.local/share/appmotel/myapp/repo/.env
# Should show: .env -> /home/appmotel/.config/appmotel/myapp/.env
```

**Check service configuration:**
```bash
sudo -u appmotel systemctl --user cat appmotel-myapp | grep -A5 "\[Service\]"
```

### Port Already in Use

**Find what's using the port:**
```bash
sudo -u appmotel ss -tlnp | grep 8000
```

**Assign new port:**
```bash
# Edit .env
sudo -u appmotel appmo env myapp
# Change PORT=8000 to PORT=8001

# Restart
sudo -u appmotel appmo restart myapp
```

### Lost Configuration After Update

Configuration should persist across updates. If lost:

**Check for backup:**
```bash
ls -la ~/.config/appmotel/myapp/.env.backup
```

**Restore backup:**
```bash
sudo -u appmotel cp ~/.config/appmotel/myapp/.env.backup ~/.config/appmotel/myapp/.env
sudo -u appmotel appmo restart myapp
```

### Permission Denied Editing .env

**From apps user (operator):**
```bash
# Use appmo env command (handles permissions)
sudo -u appmotel appmo env myapp
```

**From appmotel user:**
```bash
# Direct edit works
nano ~/.config/appmotel/myapp/.env
```

## Advanced Usage

### Templating with Multiple Environments

Create environment-specific templates:

**Template: .env.template**
```bash
PORT=
APP_NAME=
DATABASE_URL=
API_KEY=
```

**Development: .env.dev**
```bash
PORT=8000
APP_NAME="MyApp Dev"
DATABASE_URL=postgresql://localhost/myapp_dev
API_KEY=dev-key-123
```

**Production: .env.prod**
```bash
PORT=8000
APP_NAME="MyApp"
DATABASE_URL=postgresql://prod-server/myapp
API_KEY=prod-key-secure-xyz
```

Deploy with appropriate template:
```bash
# Copy production config before deploying
sudo -u appmotel cp .env.prod ~/.config/appmotel/myapp/.env
sudo -u appmotel appmo add myapp https://github.com/username/repo main
```

### Dynamic Configuration with Scripts

Use `install.sh` to generate configuration:

**install.sh:**
```bash
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

# Generate random secrets if not already set
env_file=~/.config/appmotel/myapp/.env

if ! grep -q "^SECRET_KEY=" "${env_file}" 2>/dev/null; then
  secret=$(openssl rand -hex 32)
  echo "SECRET_KEY=${secret}" >> "${env_file}"
  echo "Generated new SECRET_KEY"
fi

if ! grep -q "^JWT_SECRET=" "${env_file}" 2>/dev/null; then
  jwt=$(openssl rand -hex 32)
  echo "JWT_SECRET=${jwt}" >> "${env_file}"
  echo "Generated new JWT_SECRET"
fi
```

This automatically generates secrets on first deployment while preserving them on updates.

## See Also

- [MULTI-COMPONENT.md](MULTI-COMPONENT.md) - Multi-component app configuration
- [DEV-SETUP.md](DEV-SETUP.md) - Development environment setup
- [TESTING.md](TESTING.md) - Testing environment configuration
