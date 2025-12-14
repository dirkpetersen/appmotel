#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

echo "Installing Flask Hello World application..."

# Check if Python 3 is installed
if ! command -v python3 &> /dev/null; then
    echo "ERROR: python3 is not installed"
    echo "Please install Python 3: sudo apt-get install python3 python3-venv python3-pip"
    exit 1
fi

echo "Installation completed successfully"
