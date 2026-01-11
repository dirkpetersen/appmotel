# Multi-Component Applications

Appmotel automatically detects and deploys applications with multiple service components (e.g., frontend + backend) as a unified app.

## Supported Directory Structure

Appmotel recognizes multi-component apps in two layouts:

### Root-Level Components
```
myapp/
├── frontend/
│   ├── package.json
│   └── ...
├── backend/
│   ├── requirements.txt
│   └── ...
└── .env
```

### Src Subdirectory Components
```
myapp/
├── src/
│   ├── frontend/
│   │   ├── package.json
│   │   └── ...
│   └── backend/
│       ├── requirements.txt
│       └── ...
└── .env
```

## Recognized Component Names

Appmotel automatically detects these component directory names:

- `frontend/` - Web frontend (React, Vue, Next.js, etc.)
- `backend/` - Application backend/API
- `api/` - API server
- `worker/` - Background worker/queue processor
- `db/` - Database component
- `cache/` - Cache service

## Service Naming Convention

Each component becomes a systemd service with specific naming:

- **Frontend**: `appmotel-<app>.service` (no suffix)
  - Gets the public PORT
  - Exposed via Traefik HTTPS
  - Accessible at `https://<app>.apps.yourdomain.edu`

- **Backend**: `appmotel-<app>-backend.service`
  - Gets an internal port (not publicly accessible)
  - Other components connect via localhost

- **Other Components**: `appmotel-<app>-{component}.service`
  - Each gets an internal port
  - Not publicly accessible

## Port Allocation

- **Frontend**: Receives the main `PORT` from `.env` (or auto-assigned 10001-59999)
- **Backend/Other**: Automatically assigned sequential internal ports
- All components can communicate via localhost

## Example Configuration

### Directory Structure
```
myshop/
├── frontend/
│   ├── package.json
│   ├── next.config.js
│   └── ...
├── backend/
│   ├── requirements.txt
│   ├── app.py
│   └── ...
├── .env
└── install.sh
```

### .env File
```bash
PORT=8000
APP_NAME="MyShop"
MEMORY_LIMIT=512M
CPU_QUOTA=100%
```

### install.sh
```bash
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

echo "Installing MyShop components..."

# Frontend setup
if [[ -d frontend ]]; then
  cd frontend
  npm install
  npm run build
  cd ..
fi

# Backend setup
if [[ -d backend ]]; then
  cd backend
  python -m pip install -r requirements.txt
  cd ..
fi

echo "Installation complete"
```

## Deployment

Deploy multi-component apps the same way as single-component apps:

```bash
# Deploy from GitHub
sudo -u appmotel appmo add myshop https://github.com/username/myshop main

# Deploy from subfolder
sudo -u appmotel appmo add myshop https://github.com/username/monorepo/tree/main/apps/myshop
```

Appmotel will:
1. Detect both `frontend/` and `backend/` directories
2. Create two systemd services
3. Assign ports appropriately
4. Configure Traefik to route to frontend only

## Service Management

All `appmo` commands affect **ALL** services in the app namespace:

```bash
# Check status (shows all components)
sudo -u appmotel appmo status myshop
# Output:
# myshop (frontend): active
# myshop-backend: active

# Restart all components
sudo -u appmotel appmo restart myshop
# Restarts both frontend and backend

# View logs (shows all components)
sudo -u appmotel appmo logs myshop

# Stop all components
sudo -u appmotel appmo stop myshop

# Remove all components
sudo -u appmotel appmo remove myshop
```

## Unified App View

Multi-component apps appear as a **single app** in listings:

```bash
$ sudo -u appmotel appmo list
myshop      https://myshop.apps.yourdomain.edu    active
otherapp    https://otherapp.apps.yourdomain.edu  active
```

Use `appmo status` to see individual component details:

```bash
$ sudo -u appmotel appmo status myshop
App: myshop
URL: https://myshop.apps.yourdomain.edu
Branch: main
Status: active

Services:
  appmotel-myshop (frontend): active (running)
  appmotel-myshop-backend: active (running)
```

## Component Communication

Components can communicate via localhost using their assigned ports:

**Frontend Environment** (automatically available):
```bash
PORT=8000                    # Frontend's public port
BACKEND_PORT=8001            # Backend's internal port (example)
```

**Example**: Frontend connecting to backend
```javascript
// In your frontend code (e.g., Next.js API route)
const backendUrl = `http://localhost:${process.env.BACKEND_PORT || 8001}/api`;
const response = await fetch(`${backendUrl}/users`);
```

## Component Requirements

Each component must have:

1. **App type identifier** (one of):
   - Python: `requirements.txt` or `pyproject.toml`
   - Node.js: `package.json` with `start` script
   - Go: `go.mod`
   - Custom: `start.sh`

2. **Proper port binding**:
   - Read `PORT` environment variable
   - Bind to `0.0.0.0` or `localhost`
   - Use high ports (10001-59999)

## Automatic Framework Support

Appmotel provides automatic build and serve for common frameworks:

### Next.js Static Export (Frontend)
```json
{
  "scripts": {
    "build": "next build",
    "start": "next start"
  }
}
```

If `next.config.js` has `output: 'export'`, Appmotel:
1. Runs `npm run build`
2. Serves the `out/` directory with `serve`
3. Auto-configures the start script

### Vite + TypeScript (Frontend)
```json
{
  "scripts": {
    "build": "vite build",
    "start": "vite preview"
  }
}
```

Appmotel:
1. Runs `npm run build`
2. Serves the `dist/` directory with `serve`
3. Auto-configures the start script

### Python with Virtual Environment (Backend)
If `start.sh` exists, Appmotel:
1. Creates virtual environment in `.venv/`
2. Installs dependencies
3. Automatically adds `.venv/bin` to PATH

## Advanced Example: Full-Stack App

**Directory Structure:**
```
ecommerce/
├── frontend/              # Next.js static export
│   ├── package.json
│   ├── next.config.js
│   └── ...
├── api/                   # Python FastAPI
│   ├── requirements.txt
│   ├── main.py
│   └── ...
├── worker/                # Celery worker
│   ├── requirements.txt
│   ├── tasks.py
│   └── start.sh
├── .env
└── install.sh
```

**Deployment:**
```bash
sudo -u appmotel appmo add ecommerce https://github.com/username/ecommerce main
```

**Result:**
- `appmotel-ecommerce.service` (frontend) → Port 8000, public HTTPS
- `appmotel-ecommerce-api.service` → Port 8001, internal
- `appmotel-ecommerce-worker.service` → No port, internal

**Status:**
```bash
$ sudo -u appmotel appmo status ecommerce
App: ecommerce
URL: https://ecommerce.apps.yourdomain.edu
Services:
  appmotel-ecommerce (frontend): active
  appmotel-ecommerce-api: active
  appmotel-ecommerce-worker: active
```

## Troubleshooting

### Component Not Starting

Check individual service logs:
```bash
# View all component logs
sudo -u appmotel appmo logs myshop

# View specific component logs
sudo -u appmotel journalctl --user -u appmotel-myshop-backend -n 100
```

### Port Conflicts

Verify port assignments in service files:
```bash
# Check frontend service
sudo -u appmotel systemctl --user cat appmotel-myshop

# Check backend service
sudo -u appmotel systemctl --user cat appmotel-myshop-backend
```

### Component Communication Issues

Verify ports are accessible locally:
```bash
# Check if backend is listening
sudo -u appmotel ss -tlnp | grep 8001

# Test backend endpoint
sudo -u appmotel curl http://localhost:8001/health
```

## Best Practices

1. **Keep components independent**: Each component should be deployable separately
2. **Use environment variables**: Pass configuration via `.env` file
3. **Implement health checks**: Add `/health` endpoint to each component
4. **Log to stdout/stderr**: Systemd captures all output automatically
5. **Test locally first**: Verify component communication on localhost before deploying

## See Also

- [ENV-MANAGEMENT.md](ENV-MANAGEMENT.md) - Managing environment variables
- [TESTING.md](TESTING.md) - Testing multi-component apps
- [DEV-SETUP.md](DEV-SETUP.md) - Development environment setup
