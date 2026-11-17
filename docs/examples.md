# Appmotel Example Applications

This directory contains sample applications that demonstrate how to structure apps for Appmotel deployment.

## Available Examples

### 1. Flask Hello World (`flask-hello/`)

A simple Python Flask web application.

**Files:**
- `app.py` - Main Flask application
- `requirements.txt` - Python dependencies
- `.env` - Environment variables
- `install.sh` - Installation script

**Deploy:**
```bash
cd flask-hello
git init
git add .
git commit -m "Initial commit"
# Push to GitHub and deploy with appmo
```

### 2. Express Hello World (`express-hello/`)

A simple Node.js Express web application.

**Files:**
- `server.js` - Main Express application
- `package.json` - Node.js dependencies and start script
- `.env` - Environment variables
- `install.sh` - Installation script

**Deploy:**
```bash
cd express-hello
git init
git add .
git commit -m "Initial commit"
# Push to GitHub and deploy with appmo
```

### 3. Zensical Wiki (`zensical-wiki/`)

A documentation site built with [Zensical](https://zensical.org/). No server code needed:
Appmotel detects `zensical.toml`, installs Zensical into `.venv`, runs `zensical build`,
and serves the generated `site/` directory.

**Files:**
- `zensical.toml` - Site configuration
- `docs/` - Markdown content

**Deploy:**
```bash
appmo add zensical-test https://github.com/dirkpetersen/appmotel/tree/main/examples/zensical-wiki
```

A brand-new `zensical new` project deploys the same way. Set `site_url` in
`zensical.toml` to the app's URL (the scaffold's `example.com` placeholder only affects
canonical links and `sitemap.xml`). Add a `requirements.txt` to pin the Zensical version
or install extensions.

## Creating Your Own Application

Your application must include:

1. **`.env` file** - Environment configuration
   ```bash
   PORT=8000  # Optional, will be auto-assigned if not specified
   # Add your custom environment variables
   ```

2. **`install.sh`** - Installation script (optional)
   ```bash
   #!/usr/bin/env bash
   set -o errexit
   set -o nounset
   set -o pipefail

   echo "Running installation tasks..."
   # Add your installation logic here
   ```

3. **Application files:**
   - **Python:** `requirements.txt` + `app.py` (or single `.py` file)
   - **Node.js:** `package.json` with `scripts.start` defined
   - **Custom:** Executable in `bin/` directory

## Testing Locally

Before deploying to Appmotel, test your app locally:

**Python:**
```bash
cd flask-hello
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python3 app.py
```

**Node.js:**
```bash
cd express-hello
npm install
npm start
```

Visit `http://localhost:<PORT>` to verify your app works.
