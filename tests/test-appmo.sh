#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
IFS=$'\n\t'
# Checks for the input validation that guards isolated apps. These parts read
# values that an app user or a repo controls. No root, no appmotel needed:
#   bash tests/test-appmo.sh

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
appmo="${repo_dir}/bin/appmo"
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

failures=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    echo "ok   ${name}"
  else
    echo "FAIL ${name}: expected [${expected}], got [${actual}]"
    failures=$((failures + 1))
  fi
}

# Load single functions from bin/appmo (running it would elevate to appmotel)
for fn in python_version_request parse_env_file create_traefik_config; do
  # shellcheck source=/dev/null
  source <(sed -n "/^${fn}() {/,/^}/p" "${appmo}")
done
log_msg() { :; }
APPMO_ROLE="admin"
TRAEFIK_DYNAMIC_DIR="${work}/dynamic"
DEFAULT_RATE_LIMIT_AVG=100
DEFAULT_RATE_LIMIT_BURST=50
mkdir -p "${TRAEFIK_DYNAMIC_DIR}"

# --- python_version_request: order and refusal of unsafe values
mkdir -p "${work}/py/env" "${work}/py/file" "${work}/py/toml" "${work}/py/none" "${work}/py/bad"
echo 'PYTHON_VERSION="3.12"' > "${work}/py/env/.env"
echo '3.11' > "${work}/py/file/.python-version"
printf '[project]\nrequires-python = ">=3.10"\n' > "${work}/py/toml/pyproject.toml"
echo 'PYTHON_VERSION=3.12;rm -rf /' > "${work}/py/bad/.env"
PYTHON_VERSION=""
check "python: .env"            "3.12"   "$(python_version_request "${work}/py/env")"
check "python: .python-version" "3.11"   "$(python_version_request "${work}/py/file")"
check "python: requires-python" ">=3.10" "$(python_version_request "${work}/py/toml")"
check "python: none"            ""       "$(python_version_request "${work}/py/none")"
check "python: unsafe refused"  ""       "$(python_version_request "${work}/py/bad")"
PYTHON_VERSION="3.13"
check "python: global default"  "3.13"   "$(python_version_request "${work}/py/none")"

# --- create_traefik_config: values from the app .env must not change the YAML
yaml="${TRAEFIK_DYNAMIC_DIR}/demo.yaml"
printf 'RATE_LIMIT_AVG=1, foo: bar\nRATE_LIMIT_BURST=abc\nHEALTH_CHECK_PATH=/h"x\n' > "${work}/evil.env"
create_traefik_config demo 12345 example.org "${work}/evil.env"
check "traefik: bad avg -> default"   "1" "$(grep -c 'average: 100$' "${yaml}")"
check "traefik: bad burst -> default" "1" "$(grep -c 'burst: 50$' "${yaml}")"
check "traefik: bad health path off"  "0" "$(grep -c 'healthCheck' "${yaml}")"
check "traefik: no injected key"      "0" "$(grep -c 'foo' "${yaml}")"

printf 'RATE_LIMIT_AVG=7\nHEALTH_CHECK_PATH=/health\n' > "${work}/good.env"
create_traefik_config demo 12345 example.org "${work}/good.env"
check "traefik: good avg kept"     "1" "$(grep -c 'average: 7$' "${yaml}")"
check "traefik: good health path"  "1" "$(grep -c 'path: /health$' "${yaml}")"
check "traefik: no temp file left" "0" "$(find "${TRAEFIK_DYNAMIC_DIR}" -name '*.tmp' | wc -l)"
check "traefik: http mode, no wildcard" "0" "$(grep -c 'sans:' "${yaml}")"
LETSENCRYPT_MODE=dns create_traefik_config demo 12345 example.org "${work}/good.env"
check "traefik: dns mode wildcard"  "1" "$(grep -c '\- "\*\.example\.org"$' "${yaml}")"
check "traefik: dns mode main"      "1" "$(grep -c 'main: "example\.org"$' "${yaml}")"
check "traefik: bad port refused"  "1" "$(create_traefik_config demo '1;x' example.org "${work}/good.env" && echo 0 || echo 1)"

# --- appmotel-user: names are checked before anything else (also as non-root)
for name in 'x;id' '../etc' 'A' 'a_b' "$(printf 'a%.0s' {1..31})"; do
  out=$(bash "${repo_dir}/bin/appmotel-user" create "${name}" 2>&1 || true)
  check "appmotel-user refuses '${name:0:12}'" "1" "$(grep -c -e 'invalid app name' -e 'longer than 30' <<< "${out}")"
done

# --- install.sh find_existing_wildcard_cert: only a cert for *.BASE_DOMAIN
live="${work}/letsencrypt/live"
make_cert() {
  mkdir -p "${live}/$1"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$2" \
    -addext "subjectAltName=DNS:$2" -keyout "${live}/$1/privkey.pem" \
    -out "${live}/$1/fullchain.pem" 2>/dev/null
}
# shellcheck source=/dev/null
source <(sed -n "/^find_existing_wildcard_cert() {/,/^}/p" "${repo_dir}/install.sh" | sed "s#/etc/letsencrypt/live#${live}#g")
make_cert other '*.other.example.org'
BASE_DOMAIN="apps.example.org"
check "cert: other wildcard not used" "" "$(find_existing_wildcard_cert)"
make_cert apps '*.apps.example.org'
check "cert: matching wildcard used"  "apps" "$(find_existing_wildcard_cert)"
BASE_DOMAIN="x.apps.example.org"
check "cert: no parent-domain match"  "" "$(find_existing_wildcard_cert)"

# --- install.sh render_sudoers: the appmotel-users group may run only appmo
# shellcheck source=/dev/null
source <(sed -n "/^render_sudoers() {/,/^}/p" "${repo_dir}/install.sh")
APPMOTEL_HOME="/home/appmotel"
rules=$(render_sudoers "apps")
check "sudoers: group runs only appmo" "1" "$(grep -cxF '%appmotel-users, !%appmotel-apps ALL=(appmotel) NOPASSWD: /home/appmotel/.local/bin/appmo' <<< "${rules}")"
check "sudoers: app users excluded"    "0" "$(grep -E '^[^#].*NOPASSWD' <<< "${rules}" | grep -E '^(apps|%appmotel-users)' | grep -vc '!%appmotel-apps')"
if command -v visudo >/dev/null 2>&1 && visudo -cf /dev/null >/dev/null 2>&1; then
  printf '%s\n' "${rules}" > "${work}/sudoers"
  check "sudoers: visudo accepts it" "0" "$(visudo -cf "${work}/sudoers" >/dev/null 2>&1; echo $?)"
fi

echo
if [[ ${failures} -gt 0 ]]; then
  echo "${failures} check(s) failed"
  exit 1
fi
echo "all checks passed"
