#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
IFS=$'\n\t'

# ==========================================
# LINUX HOME DIRECTORY RESET SCRIPT
# ==========================================
# Usage from repository root:
#   sudo -u appmotel bash bin/reset-home.sh --force
#
# This script should NOT be made executable
# Must be run as the appmotel user (not root)
# ==========================================

# The only user whose home this script is allowed to wipe
readonly EXPECTED_USER="appmotel"

# Parse command line arguments
FORCE_MODE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE_MODE=1
fi

# 1. SAFETY CHECKS
# ----------------
# Get the name of this script so we don't delete it
SCRIPT_NAME=$(basename "$0")

# Ensure the script is NOT run as root (sudo).
# We want to reset the current user's home, not /root.
if [[ ${EUID} -eq 0 ]]; then
  echo "❌ ERROR: Please run this as the ${EXPECTED_USER} user, NOT as root."
  echo "   Usage: sudo -u ${EXPECTED_USER} bash bin/reset-home.sh --force"
  exit 1
fi

# Ensure we are the intended service user: running this as the operator
# account by mistake (forgetting the sudo -u prefix) would irreversibly
# wipe the operator's home, including this repository checkout.
if [[ "$(id -un)" != "${EXPECTED_USER}" ]]; then
  echo "❌ ERROR: This script resets the ${EXPECTED_USER} home directory and"
  echo "   must run as that user, not '$(id -un)'."
  echo "   Usage: sudo -u ${EXPECTED_USER} bash bin/reset-home.sh --force"
  exit 1
fi

# Ensure we are actually in the HOME directory before starting
cd "$HOME" || { echo "Could not enter home directory"; exit 1; }

# 2. CONFIRMATION
# ----------------
if [[ ${FORCE_MODE} -eq 0 ]]; then
  echo "⚠️  WARNING: YOU ARE ABOUT TO RESET: $HOME"
  echo "   - ALL files (Hidden & Visible) will be DELETED."
  echo "   - This script (${SCRIPT_NAME}) will be preserved."
  echo "   - Skeleton files will be restored."
  echo ""
  read -p "Are you sure you want to proceed? (Type 'y' to confirm): " -n 1 -r || REPLY=""
  echo ""
  if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 1
  fi
  echo "----------------------------------------"
else
  echo "⚠️  FORCE MODE: Resetting $HOME without confirmation"
  echo "----------------------------------------"
fi

# 3. WIPE DIRECTORY
# ----------------
echo "🧹 Cleaning directory..."
# find $HOME:      Look in home
# -mindepth 1:     Ignore the folder itself (don't delete /home/user)
# ! -name ...:     EXCLUDE this script file
# -delete:         Delete everything else
# Busy/undeletable entries must fail loudly, not print "Success!" below
if ! find "$HOME" -mindepth 1 ! -name "${SCRIPT_NAME}" -delete; then
  echo "❌ ERROR: Some files could not be deleted; home is partially reset."
  exit 1
fi

# 4. RESTORE SKELETON
# ----------------
echo "💀 Copying skeleton files..."
# Copy contents of /etc/skel to current folder (hidden files included)
# Since we are running as the user, 'chown' is not required.
cp -r /etc/skel/. "$HOME"

# 5. FORCE BASH RELOAD (Optional)
# ----------------
# Re-source the new .bashrc so the terminal looks right immediately
if [[ -f "$HOME/.bashrc" ]]; then
    # .bashrc is not written for nounset/errexit; relax for sourcing
    set +o errexit +o nounset
    source "$HOME/.bashrc"
    set -o errexit -o nounset
fi

echo "✅ Success! Your Home Directory has been reset."
