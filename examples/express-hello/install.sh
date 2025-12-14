#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

echo "Installing Express Hello World application..."

# Check if Node.js is installed
if ! command -v node &> /dev/null; then
    echo "ERROR: Node.js is not installed"
    echo "Please install Node.js: sudo apt-get install nodejs npm"
    exit 1
fi

echo "Node.js version: $(node --version)"
echo "npm version: $(npm --version)"
echo "Installation completed successfully"
