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
for fn in python_version_request parse_env_file create_traefik_config setup_app_env_file update_port_in_env; do
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

# --- setup_app_env_file: a subfolder app does not get a parent's template
APPS_CONFIG_DIR="${work}/cfg"; APPS_DATA_DIR="${work}/data"
mkdir -p "${APPS_DATA_DIR}/sub/repo/examples/hello" "${APPS_DATA_DIR}/own/repo/app"
echo 'USE_LETSENCRYPT=no' > "${APPS_DATA_DIR}/sub/repo/.env.default"
echo 'GREETING=hi' > "${APPS_DATA_DIR}/own/repo/app/.env.example"
setup_app_env_file sub 12345 examples/hello
check "env: parent template ignored" "PORT=12345" "$(cat "${APPS_CONFIG_DIR}/sub/.env")"
setup_app_env_file own 12346 app
check "env: own template used"       "GREETING=hi PORT=12346" "$(tr '\n' ' ' < "${APPS_CONFIG_DIR}/own/.env" | sed 's/ $//')"

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

# --- install.sh resolve_bind_ip: keep a hand-set IP, refuse bad values
# shellcheck source=/dev/null
source <(sed -n "/^resolve_bind_ip() {/,/^}/p" "${repo_dir}/install.sh")
die() { echo "DIE"; exit 1; }
b="${work}/bind"; mkdir -p "${b}"; : > "${b}/none.env"
printf 'entryPoints:\n  web:\n    address: "192.0.2.40:80"\n' > "${b}/ip.yaml"
printf 'entryPoints:\n  web:\n    address: 192.0.2.5:80\n' > "${b}/bare.yaml"
printf 'entryPoints:\n  web:\n    address: ":80"\n' > "${b}/all.yaml"
printf 'entryPoints:\n  web:\n    address: "[2001:db8::5]:80"\n' > "${b}/v6.yaml"
echo 'APPMOTEL_BIND_IP=""' > "${b}/empty.env"
bind() { (APPMOTEL_BIND_IP="$3" resolve_bind_ip "${b}/$1" "${b}/$2") 2>/dev/null; }
check "bind: keep yaml IP"         "192.0.2.40" "$(bind ip.yaml none.env '')"
check "bind: keep unquoted IP"     "192.0.2.5"    "$(bind bare.yaml none.env '')"
check "bind: keep IPv6"            "[2001:db8::5]"   "$(bind v6.yaml none.env '')"
check "bind: default all"          ""            "$(bind all.yaml none.env '')"
check "bind: .env wins"            "198.51.100.3"    "$(echo 'APPMOTEL_BIND_IP=x' > "${b}/set.env"; bind ip.yaml set.env 198.51.100.3)"
check "bind: empty .env = all"     ""            "$(bind ip.yaml empty.env '')"
check "bind: first install env"   "198.51.100.9"    "$(bind all.yaml none.env 198.51.100.9)"
check "bind: bad IP refused"       "DIE"         "$(bind all.yaml set.env '1.2.3.4:99 #')"
check "bind: octet > 255 refused"  "DIE"         "$(bind all.yaml set.env 192.0.2.300)"

# --- install.sh resolve_operator_users: appmotel-ops is always an operator
# shellcheck source=/dev/null
source <(sed -n "/^resolve_operator_users() {/,/^}/p" "${repo_dir}/install.sh")
die() { echo "DIE"; }
ops() { OPERATOR_USERS="$1" resolve_operator_users /nonexistent; }
check "ops: default"           "apps,%appmotel-ops"       "$(ops '')"
check "ops: list gets group"   "apps,joe,%appmotel-ops"   "$(ops 'apps joe')"
check "ops: group not doubled" "%appmotel-ops"            "$(ops '%appmotel-ops')"
check "ops: ALL stays ALL"     "ALL"                      "$(ops 'ALL')"

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
