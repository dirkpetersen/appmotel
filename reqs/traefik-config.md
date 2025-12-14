# 

Here is the updated configuration.

To satisfy your request of using a **Config Directory** instead of a specific file argument, we will leverage Traefik's native **Auto-Discovery**. If we set the `XDG_CONFIG_HOME` environment variable correctly, Traefik will automatically look inside `/home/appmotel/.config/traefik/` for a `traefik.yaml` file. We do not need to pass the filename to the executable.

### Step 1: Install Binary & Create Paths (Run as `appmotel`)

Log in as `appmotel`. We will place the binary in `.local/bin`.

```bash
# 1. Create the binary directory
mkdir -p ~/.local/bin

# 2. Download/Move Traefik binary here
# (Assuming you have the binary, move it):
# mv /path/to/downloaded/traefik ~/.local/bin/traefik

# 3. Make it executable
chmod +x ~/.local/bin/traefik

# 4. Create Config & Data Directories
mkdir -p ~/.config/traefik
mkdir -p ~/.config/traefik/dynamic  # Folder for your routers/services files
mkdir -p ~/.local/share/traefik

# 5. Create empty ACME file and secure it
touch ~/.local/share/traefik/acme.json
chmod 600 ~/.local/share/traefik/acme.json
```

### Step 2: Configure Traefik to use Directories (Run as `appmotel`)`

Create the main **Static** configuration file. Traefik will find this automatically.

File: `~/.config/traefik/traefik.yaml`

```yaml
# STATIC CONFIGURATION

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

# Tell Traefik to look for DYNAMIC config (routers/services) in a directory
providers:
  file:
    directory: "/home/appmotel/.config/traefik/dynamic"
    watch: true

certificatesResolvers:
  myresolver:
    acme:
      storage: "/home/appmotel/.local/share/traefik/acme.json"
      httpChallenge:
        entryPoint: web

api:
  dashboard: true

log:
  level: INFO
```

**IMPORTANT - TLS Configuration Notes (Traefik v3):**

1. **TLS certificate stores MUST be in dynamic configuration, NOT static configuration**. If using existing certificates (e.g., Let's Encrypt managed externally), create a separate TLS config file in the dynamic directory.

2. **Router TLS sections must use `tls: {}` (empty object), NOT `tls:` (null/empty)**. The empty object syntax properly enables TLS termination.

Now you can put any number of YAML files for your apps inside `~/.config/traefik/dynamic/`.

**Example TLS Configuration File** (if using external certificates):

File: `~/.config/traefik/dynamic/tls-config.yaml`

```yaml
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/letsencrypt/live/yourdomain.edu/fullchain.pem
        keyFile: /etc/letsencrypt/live/yourdomain.edu/privkey.pem
```

**Example Application Router** (dynamic config):

File: `~/.config/traefik/dynamic/myapp.yaml`

```yaml
http:
  routers:
    myapp:
      rule: "Host(`myapp.yourdomain.edu`)"
      entryPoints:
        - websecure
      service: myapp
      tls: {}  # IMPORTANT: Use empty object, not null

  services:
    myapp:
      loadBalancer:
        servers:
          - url: "http://localhost:8000"
        healthCheck:
          path: /health
          interval: 30s
          timeout: 5s
```

### Step 3: Create the Systemd Service (Run as `sudo`)

We will update the service. Notice:
1.  **ExecStart**: Points to `~/.local/bin`.
2.  **Arguments**: No `--configFile` argument is used.
3.  **Environment**: `XDG_CONFIG_HOME` is set so Traefik knows where to look.

File: `/etc/systemd/system/traefik-appmotel.service`

```ini
[Unit]
Description=Traefik Proxy (AppMotel)
Documentation=https://doc.traefik.io/traefik/
After=network-online.target
Wants=network-online.target

[Service]
# 1. Run as appmotel
User=appmotel
Group=appmotel

# 2. Define XDG Environment Variables
# Traefik will auto-discover config in $XDG_CONFIG_HOME/traefik/traefik.yaml
Environment="XDG_CONFIG_HOME=/home/appmotel/.config"
Environment="XDG_DATA_HOME=/home/appmotel/.local/share"

# 3. Grant permission to bind Port 80 and 443
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# 4. Point to the binary in .local/bin
# We do NOT specify --configFile; we rely on XDG auto-discovery
ExecStart=/home/appmotel/.local/bin/traefik

# Security & Recovery
Restart=always
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
```

### Step 4: Allow User to Restart (Run as `sudo`)

put this is /etc/sudoers.d/appmotel so `appmotel` can restart the service.

```text
appmotel ALL=(ALL) NOPASSWD: /bin/systemctl restart traefik-appmotel, /bin/systemctl stop traefik-appmotel, /bin/systemctl start traefik-appmotel, /bin/systemctl status traefik-appmotel
```

### Step 5: Activate

```bash
# 1. Reload Systemd to see the new file location
sudo systemctl daemon-reload

# 2. Start the service
sudo systemctl enable --now traefik-appmotel

# 3. Check status (as appmotel)
systemctl status traefik-appmotel
```

### How this works specifically
1.  **Binary:** Systemd launches `/home/appmotel/.local/bin/traefik`.
2.  **Discovery:** Traefik starts up. It sees no `--configFile` argument.
3.  **XDG:** It checks `$XDG_CONFIG_HOME` (which we set to `/home/appmotel/.config`).
4.  **Load:** It automatically loads `/home/appmotel/.config/traefik/traefik.yaml`.
5.  **Dynamic:** That file tells Traefik to scan `/home/appmotel/.config/traefik/dynamic/` for all other configuration files.
