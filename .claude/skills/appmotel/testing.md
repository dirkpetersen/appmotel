# Appmotel Testing and Development

## Clean Install Testing

```bash
sudo -u appmotel bash bin/reset-home.sh --force  # Reset appmotel home
sudo bash install.sh                              # System-level setup (root)
sudo -u appmotel bash install.sh                  # User-level setup
```

## Syntax Validation

```bash
bash -n install.sh
bash -n bin/appmo
bash -n /home/appmotel/install.sh
```

## Test App Deployment

```bash
# Deploy test Flask app
appmo add flask-test https://github.com/dirkpetersen/appmotel main examples/flask-hello

appmo status flask-test
appmo logs flask-test 50

# Test access
curl -I http://flask-test.apps.yourdomain.edu    # Should redirect to HTTPS
curl https://flask-test.apps.yourdomain.edu

# Cleanup
appmo remove flask-test
```
