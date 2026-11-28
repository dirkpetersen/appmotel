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
for fn in python_version_request parse_env_file create_traefik_config setup_app_env_file update_port_in_env safe_source_env env_get_value env_set_value env_set_lines env_unset_value \
          json_escape notify schedule_parse_line restart_limit_directives apply_restart_limit remove_scheduled_jobs sync_scheduled_jobs \
          job_units unit_props is_counter human_bytes format_cpu_time backup_retention validate_backup_id \
          rollback_target create_backup check_disk_space get_all_services get_app_unit_files verify_result \
          verify_backup safe_source_metadata safe_rm_rf check_crash_loop cert_end_epoch list_tls_certs cmd_logs \
          restore_backup restore_app_deps systemctl_stop find_file_up is_zensical_site \
          save_app_metadata load_app_metadata is_multi_component parse_procfile; do
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

# --- env_set_value / env_get_value: what 'appmo env <app> set|get' writes and reads
die() { echo "DIE: $*" >&2; exit 1; }
ef="${work}/set.env"
printf '# comment\nPORT=10001\nDB=old\nDB=dup\n' > "${ef}"
env_set_value "${ef}" DB "new"
check "env set: replaces, drops dup" "PORT=10001|DB=new" "$(grep -v '^#' "${ef}" | paste -sd'|')"
env_set_value "${ef}" MSG "hello world #1"
check "env set: spaces quoted"   "MSG='hello world #1'" "$(grep '^MSG=' "${ef}")"
env_set_value "${ef}" Q "it's"
check "env set: single quote"    "Q=\"it's\""   "$(grep '^Q=' "${ef}")"
check "env get: plain"           "10001"          "$(env_get_value "${ef}" PORT)"
check "env get: strips quotes"   "hello world #1" "$(env_get_value "${ef}" MSG)"
check "env get: missing -> 1"    "1"              "$(env_get_value "${ef}" NOPE >/dev/null; echo $?)"
check "env set: \$( refused"     "1" "$( (env_set_value "${ef}" X 'a$(id)') 2>/dev/null; echo $?)"
check "env set: ; refused"       "1" "$( (env_set_value "${ef}" X 'a;b') 2>/dev/null; echo $?)"
check "env set: bad name refused" "1" "$( (env_set_value "${ef}" '1X' v) 2>/dev/null; echo $?)"
check "env set: both quotes refused" "1" "$( (env_set_value "${ef}" X "a'\"b") 2>/dev/null; echo $?)"
check "env set: refused leaves file" "0" "$(grep -c '^X=' "${ef}")"
( safe_source_env "${ef}" true; printf '%s|%s|%s' "${DB}" "${MSG}" "${Q}" ) > "${work}/src.out"
check "env set: safe_source_env reads it" "new|hello world #1|it's" "$(cat "${work}/src.out")"
printf 'A=1\n# note\n\nB="two words"\nC=x\n' | env_set_lines "${ef}" 2>/dev/null
check "env set stdin: many lines" "1|two words|x" "$(env_get_value "${ef}" A)|$(env_get_value "${ef}" B)|$(env_get_value "${ef}" C)"
before=$(md5sum < "${ef}")
check "env set stdin: bad line -> 1" "1" "$( (printf 'D=1\nE=a;b\n' | env_set_lines "${ef}") 2>/dev/null; echo $?)"
check "env set stdin: all or none" "${before}" "$(md5sum < "${ef}")"
check "env set stdin: no temp left" "0" "$(find "${work}" -name 'set.env.*' | wc -l)"
cp "${ef}" "${work}/unset.env"; printf 'A=again\n' >> "${work}/unset.env"
env_unset_value "${work}/unset.env" A
check "env unset: all A lines gone" "0|10001" "$(grep -c '^A=' "${work}/unset.env")|$(env_get_value "${work}/unset.env" PORT)"
check "env unset: missing -> 1"     "1" "$(env_unset_value "${work}/unset.env" NOPE; echo $?)"
if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --wait --pipe true >/dev/null 2>&1; then
  check "env set: systemd reads it" "new|hello world #1|it's" \
    "$(systemd-run --user --wait --pipe -q -p EnvironmentFile="${ef}" sh -c 'printf "%s|%s|%s" "$DB" "$MSG" "$Q"')"
fi

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

# --- operations features: per-test directories, like the appmotel home
ops="${work}/ops"
APPMO_HOME="${ops}/home"
APPS_CONFIG_DIR="${ops}/cfg"; APPS_DATA_DIR="${ops}/data"; BACKUPS_DIR="${ops}/backups"
SYSTEMD_USER_DIR="${ops}/units"; TRAEFIK_DYNAMIC_DIR="${ops}/dynamic"
DEFAULT_MEMORY_LIMIT="512M"; DEFAULT_CPU_QUOTA="100%"
SCHEDULE_FILE_NAME="appmo-schedule"; MAX_SCHEDULED_JOBS=20; CRASH_LOOP_RESTARTS=3
mkdir -p "${APPMO_HOME}" "${APPS_CONFIG_DIR}" "${APPS_DATA_DIR}" "${SYSTEMD_USER_DIR}" "${TRAEFIK_DYNAMIC_DIR}"
die() { echo "DIE: $*"; exit 1; }
cleanup_temp_files() { :; }

# --- json_escape / notify: the webhook gets valid JSON, the app URL wins
check "json: escapes" '{"text": "a\"b\\c\nd\te"}' \
  "$(printf '{"text": "%s"}' "$(json_escape "$(printf 'a"b\\c\nd\te\001')")")"
curl() { cat > "${ops}/curl.body"; printf '%s\n' "$@" > "${ops}/curl.args"; }
NOTIFY_WEBHOOK_URL="https://hooks.example.org/global"; BASE_DOMAIN="apps.example.org"
mkdir -p "${APPS_CONFIG_DIR}/nfy"; : > "${APPS_CONFIG_DIR}/nfy/.env"
notify nfy 'deployed "main" a -> b'
check "notify: valid JSON" 'appmotel apps.example.org: nfy: deployed "main" a -> b' \
  "$(python3 -c 'import json, sys; print(json.load(sys.stdin)["text"])' < "${ops}/curl.body")"
check "notify: global URL"   "https://hooks.example.org/global" "$(tail -n 1 "${ops}/curl.args")"
echo 'NOTIFY_WEBHOOK_URL=https://hooks.example.org/app' > "${APPS_CONFIG_DIR}/nfy/.env"
notify nfy x
check "notify: app URL wins" "https://hooks.example.org/app" "$(tail -n 1 "${ops}/curl.args")"
: > "${APPS_CONFIG_DIR}/nfy/.env"; rm -f "${ops}/curl.args"
APPMO_ROLE="app"; notify nfy x; APPMO_ROLE="admin"
check "notify: app role has no global URL" "no" "$([[ -f "${ops}/curl.args" ]] && echo yes || echo no)"
echo 'NOTIFY_WEBHOOK_URL=file:///etc/passwd' > "${APPS_CONFIG_DIR}/nfy/.env"; NOTIFY_WEBHOOK_URL=""
notify nfy x
check "notify: non-http URL refused" "no" "$([[ -f "${ops}/curl.args" ]] && echo yes || echo no)"
unset -f curl

# --- schedule_parse_line: "<calendar> | <command>", nothing else
sp() { local c="" m="" rc=0; schedule_parse_line "$1" c m || rc=$?; printf '%s|%s|%s' "${rc}" "${c}" "${m}"; }
check "schedule: plain"          "0|daily|python3 job.py"        "$(sp 'daily | python3 job.py')"
check "schedule: pipe in command" "0|*-*-* 02:30:00|a | b"       "$(sp '*-*-* 02:30:00 | a | b')"
check "schedule: CRLF"           "0|hourly|echo hi"              "$(sp $'hourly | echo hi\r')"
check "schedule: comment"        "1||"                           "$(sp '  # nightly')"
check "schedule: blank"          "1||"                           "$(sp '')"
check "schedule: no separator"   "2||"                           "$(sp 'daily python3 job.py')"
check "schedule: no command"     "2||"                           "$(sp 'daily | ')"
check "schedule: % refused"      "2||"                           "$(sp 'daily%n | x')"
check "schedule: ; refused"      "2||"                           "$(sp 'daily;x | y')"
check "schedule: \\ refused"     "2||"                           "$(sp 'daily\ | y')"
check "schedule: option refused" "2||"                           "$(sp '--help | x')"

# --- restart_limit_directives: only a sane RESTART_LIMIT turns it on
re="${ops}/restart.env"
echo 'RESTART_LIMIT=5' > "${re}"
check "restart: limit"           "StartLimitIntervalSec=300|StartLimitBurst=5" "$(restart_limit_directives "${re}" | paste -sd'|')"
printf 'RESTART_LIMIT=08\nRESTART_WINDOW=600\n' > "${re}"
check "restart: window, decimal" "StartLimitIntervalSec=600|StartLimitBurst=8" "$(restart_limit_directives "${re}" | paste -sd'|')"
printf 'RESTART_LIMIT=5\nRESTART_WINDOW=1;x\n' > "${re}"
check "restart: bad window"      "StartLimitIntervalSec=300|StartLimitBurst=5" "$(restart_limit_directives "${re}" | paste -sd'|')"
for bad in '5;x' 0 101 abc; do
  echo "RESTART_LIMIT=${bad}" > "${re}"
  check "restart: '${bad}' ignored" "" "$(restart_limit_directives "${re}")"
done
: > "${re}"
check "restart: off by default"  "" "$(restart_limit_directives "${re}")"

# --- appmo top formatting
check "bytes: B"         "512B"   "$(human_bytes 512)"
check "bytes: K"         "1.5K"   "$(human_bytes 1536)"
check "bytes: M"         "512.0M" "$(human_bytes 536870912)"
check "bytes: untracked" "-"      "$(human_bytes 18446744073709551615)"
check "bytes: not set"   "-"      "$(human_bytes '[not set]')"
check "bytes: infinity"  "-"      "$(human_bytes infinity)"
check "cpu: seconds"     "4.2s"   "$(format_cpu_time 4200000000)"
check "cpu: minutes"     "3m07s"  "$(format_cpu_time 187000000000)"
check "cpu: hours"       "5h02m"  "$(format_cpu_time 18120000000000)"
check "cpu: untracked"   "-"      "$(format_cpu_time '')"

# --- backups: COMMIT, rollback target, backup id, retention, verify
check "backup id: traversal refused" "DIE" "$( (validate_backup_id '../x') | cut -c1-3)"
check "backup id: slash refused"     "DIE" "$( (validate_backup_id 'a/b') | cut -c1-3)"
check "backup id: normal"            "ok"  "$( (validate_backup_id '2026-01-31-120000-1') && echo ok)"
bk_repo="${APPS_DATA_DIR}/bk/repo"
mkdir -p "${bk_repo}" "${APPS_CONFIG_DIR}/bk"
git -C "${bk_repo}" init -q
bk_commit() { git -C "${bk_repo}" -c user.name=t -c user.email=t@example.org commit -q --allow-empty -m "$1"; }
bk_commit one
printf 'APP_NAME="bk"\nPORT="12001"\n' > "${APPS_CONFIG_DIR}/bk/metadata.conf"
echo 'PORT=12001' > "${APPS_CONFIG_DIR}/bk/.env"
printf '[Service]\nExecStart=/bin/true\n' > "${SYSTEMD_USER_DIR}/appmotel-bk.service"
printf 'http:\n  routers:\n    bk: {}\n' > "${TRAEFIK_DYNAMIC_DIR}/bk.yaml"
check "retention: default" "5" "$(backup_retention bk)"
echo 'BACKUP_RETENTION=0' >> "${APPS_CONFIG_DIR}/bk/.env"
check "retention: 0 -> 5"  "5" "$(backup_retention bk)"
printf 'PORT=12001\nBACKUP_RETENTION=3\n' > "${APPS_CONFIG_DIR}/bk/.env"
check "retention: set"     "3" "$(backup_retention bk)"
head1=$(git -C "${bk_repo}" rev-parse HEAD)
id1=$(create_backup bk)
bk_commit two
head2=$(git -C "${bk_repo}" rev-parse HEAD)
id2=$(create_backup bk)
check "backup: COMMIT recorded"     "${head2}" "$(cat "${BACKUPS_DIR}/bk/${id2}/COMMIT")"
check "backup: same second, own id" "yes" "$([[ "${id1}" != "${id2}" && -d "${BACKUPS_DIR}/bk/${id1}" ]] && echo yes)"
check "rollback: version before"    "${id1}" "$(rollback_target bk "${head2}")"
check "rollback: newest other"      "${id2}" "$(rollback_target bk "${head1}")"
id3=$(create_backup bk)
check "rollback: skips same commit" "${id1}" "$(rollback_target bk "${head2}")"
rm -f "${BACKUPS_DIR}/bk/${id1}/COMMIT"
check "rollback: none older -> 1"   "1" "$(rollback_target bk "${head2}" >/dev/null; echo $?)"
rm -f "${BACKUPS_DIR}/bk"/*/COMMIT
check "rollback: old backups, newest" "${id3}" "$(rollback_target bk "${head2}")"
check "verify: good backup"     "0" "$( (verify_backup bk "${id2}") >/dev/null 2>&1; echo $?)"
check "verify: no temp dir left" "0" "$(find "${BACKUPS_DIR}" -maxdepth 1 -name '.verify.*' | wc -l)"
echo "${head1}" > "${BACKUPS_DIR}/bk/${id2}/COMMIT"
check "verify: wrong COMMIT"    "1" "$( (verify_backup bk "${id2}") >/dev/null 2>&1; echo $?)"
rm -f "${BACKUPS_DIR}/bk/${id2}/COMMIT"
head -c 200 "${BACKUPS_DIR}/bk/${id2}/repo.tar.gz" > "${ops}/cut.tgz"
mv "${ops}/cut.tgz" "${BACKUPS_DIR}/bk/${id2}/repo.tar.gz"
check "verify: truncated archive" "1" "$( (verify_backup bk "${id2}") >/dev/null 2>&1; echo $?)"
check "verify: says why"        "1" "$( (verify_backup bk "${id2}") 2>/dev/null | grep -c 'damaged or truncated')"
rm -f "${BACKUPS_DIR}/bk/${id3}/appmotel-bk.service"
check "verify: missing unit"    "1" "$( (verify_backup bk "${id3}") 2>/dev/null | grep -c 'no systemd unit')"
create_backup bk keep-all >/dev/null
check "backup: keep-all prunes nothing" "4" "$(find "${BACKUPS_DIR}/bk" -mindepth 1 -maxdepth 1 -type d | wc -l)"

# Update c1 -> c2 -> c3 made backups of c1 and c2; a rollback backs up c3 first
rb="${BACKUPS_DIR}/rb"
mkdir -p "${rb}/2026-01-01-100000" "${rb}/2026-01-02-100000" "${rb}/2026-01-03-100000"
echo c1 > "${rb}/2026-01-01-100000/COMMIT"; echo c2 > "${rb}/2026-01-02-100000/COMMIT"
check "rollback: first goes to c2"         "2026-01-02-100000" "$(rollback_target rb c3)"
echo c3 > "${rb}/2026-01-03-100000/COMMIT"; touch "${rb}/2026-01-03-100000/ROLLBACK_SAFETY"
check "rollback: second goes further back" "2026-01-01-100000" "$(rollback_target rb c2)"
mkdir -p "${rb}/2026-01-04-100000-9" "${rb}/2026-01-04-100000-10"
echo c9 > "${rb}/2026-01-04-100000-9/COMMIT"; echo c10 > "${rb}/2026-01-04-100000-10/COMMIT"
check "rollback: -10 is newer than -9"     "2026-01-04-100000-10" "$(rollback_target rb c2)"

# --- unit_props: a missing unit reads as not-found (needs a user manager)
if systemctl --user show -p LoadState no-such-unit.service >/dev/null 2>&1; then
  declare -A up=()
  unit_props "appmotel-no-such-unit.service" up LoadState ActiveState
  check "unit_props: missing unit" "not-found|inactive" "${up[LoadState]:-}|${up[ActiveState]:-}"
fi

# --- check_crash_loop: restarts between two runs, or the restart limit
cl_state="active"; cl_result="success"; cl_restarts=0
systemctl() {
  if [[ "${2:-}" == "show" ]]; then
    printf 'ActiveState=%s\nResult=%s\nNRestarts=%s\n' "${cl_state}" "${cl_result}" "${cl_restarts}"
  fi
}
notify() { echo "$2" >> "${ops}/notify.log"; }
: > "${ops}/notify.log"
crash() { cl_restarts="$1"; check_crash_loop bk; wc -l < "${ops}/notify.log" | tr -d ' '; }
check "crash: first run only counts" "0" "$(crash 2)"
check "crash: +2 is no loop"         "0" "$(crash 4)"
check "crash: +3 is a loop"          "1" "$(crash 7)"
check "crash: once an hour"          "1" "$(crash 10)"
rm -f "${APPS_DATA_DIR}/bk/.crash-loop-reported"
cl_state="failed"; cl_result="start-limit-hit"
check "crash: restart limit hit"     "2" "$(crash 10)"
check "crash: says which"            "1" "$(grep -c 'appmotel-bk (systemd stopped restarting it)' "${ops}/notify.log")"
cl_state="active"; cl_result="success"
crash 10 >/dev/null
check "crash: quiet run keeps stamp" "yes" "$([[ -f "${APPS_DATA_DIR}/bk/.crash-loop-reported" ]] && echo yes || echo no)"
check "crash: +2/+3 in turn, once"   "2" "$(crash 12 >/dev/null; crash 15)"
# What systemd really shows when the start limit ends the restarts
rm -f "${APPS_DATA_DIR}/bk/.crash-loop-reported"
cl_state="failed"; cl_result="exit-code"
check "crash: limit with exit-code"  "3" "$(crash 15)"
cl_state="failed"; cl_result="exit-code"; cl_restarts=0
rm -f "${APPS_DATA_DIR}/bk/.crash-loop-reported"
check "crash: one failed run is no loop" "3" "$(crash 0)"
cl_state="active"; cl_result="success"

systemctl() { local IFS=' '; echo "systemctl $*" >> "${ops}/systemctl.log"; }

# --- apply_restart_limit: a drop-in per unit, rewritten only on change
dropin="${SYSTEMD_USER_DIR}/appmotel-bk.service.d/restart-limit.conf"
printf 'PORT=12001\nRESTART_LIMIT=4\n' > "${APPS_CONFIG_DIR}/bk/.env"
: > "${ops}/systemctl.log"
apply_restart_limit bk
check "restart drop-in: written"    "[Unit]|StartLimitIntervalSec=300|StartLimitBurst=4" "$(grep -v '^#' "${dropin}" | paste -sd'|')"
check "restart drop-in: reload"     "1" "$(grep -c 'daemon-reload' "${ops}/systemctl.log")"
apply_restart_limit bk
check "restart drop-in: no change, no reload" "1" "$(grep -c 'daemon-reload' "${ops}/systemctl.log")"
if command -v systemd-analyze >/dev/null 2>&1; then
  cp "${dropin}" "${ops}/check-dropin.conf"
  printf '[Unit]\nDescription=x\n[Service]\nExecStart=/bin/true\n' > "${ops}/check.service"
  check "restart drop-in: systemd accepts it" "0" \
    "$(cat "${ops}/check.service" "${ops}/check-dropin.conf" > "${ops}/merged.service"; systemd-analyze --user verify --man=no "${ops}/merged.service" >/dev/null 2>&1; echo $?)"
fi
printf 'PORT=12001\n' > "${APPS_CONFIG_DIR}/bk/.env"
apply_restart_limit bk
check "restart drop-in: removed"    "no|no" "$([[ -f "${dropin}" ]] && echo yes || echo no)|$([[ -d "${dropin%/*}" ]] && echo yes || echo no)"

# --- sync_scheduled_jobs: units, scripts, venv, limits; bad lines skipped
job_dir="${APPS_DATA_DIR}/job/repo/app"
mkdir -p "${job_dir}" "${APPS_DATA_DIR}/job/repo/.venv/bin" "${APPS_CONFIG_DIR}/job"
printf '#!/bin/sh\n' > "${APPS_DATA_DIR}/job/repo/.venv/bin/python3"; chmod +x "${APPS_DATA_DIR}/job/repo/.venv/bin/python3"
printf 'PORT=12002\nMEMORY_LIMIT=256M\nJOB_TIMEOUT=2h\n' > "${APPS_CONFIG_DIR}/job/.env"
cat > "${job_dir}/appmo-schedule" <<'EOF'
# nightly report
daily | python3 report.py --all
*-*-* 02:30:00 | echo "it's 2:30" | tee -a /tmp/x
not a job line
Mon..Fri 08:00 | true
bogus calendar | true
EOF
sync_scheduled_jobs job "${job_dir}"
job1="${SYSTEMD_USER_DIR}/appmotel-job.job-1"
check "jobs: three of five lines"  "appmotel-job.job-1 appmotel-job.job-2 appmotel-job.job-3" "$(paste -sd' ' "${APPS_CONFIG_DIR}/job/jobs.list")"
check "jobs: calendar in timer"    "OnCalendar=*-*-* 02:30:00" "$(grep '^OnCalendar=' "${SYSTEMD_USER_DIR}/appmotel-job.job-2.timer")"
check "jobs: command verbatim"     "echo \"it's 2:30\" | tee -a /tmp/x" "$(tail -n 1 "${APPS_CONFIG_DIR}/job/jobs/job-2.sh")"
check "jobs: app .env"             "EnvironmentFile=${APPS_CONFIG_DIR}/job/.env" "$(grep '^EnvironmentFile=' "${job1}.service")"
check "jobs: venv on PATH"         "1" "$(grep -c "PATH=${APPS_DATA_DIR}/job/repo/.venv/bin:" "${job1}.service")"
check "jobs: memory limit"         "MemoryMax=256M" "$(grep '^MemoryMax=' "${job1}.service")"
check "jobs: timeout"              "TimeoutStartSec=2h" "$(grep '^TimeoutStartSec=' "${job1}.service")"
check "jobs: in app folder"        "WorkingDirectory=${job_dir}" "$(grep '^WorkingDirectory=' "${job1}.service")"
check "jobs: timers enabled"       "3" "$(grep -c 'enable --now appmotel-job.job-[0-9].timer' "${ops}/systemctl.log")"
if command -v systemd-analyze >/dev/null 2>&1; then
  check "jobs: systemd accepts units" "0" "$(systemd-analyze --user verify --man=no "${job1}.service" "${job1}.timer" >/dev/null 2>&1; echo $?)"
fi
check "jobs: job_units"            "3" "$(job_units job | wc -l)"
echo 'weekly | true' > "${job_dir}/appmo-schedule"
sync_scheduled_jobs job "${job_dir}"
check "jobs: resync drops old"     "2" "$(find "${SYSTEMD_USER_DIR}" -name 'appmotel-job.job-*' | wc -l)"
remove_scheduled_jobs job
printf '[Service]\nExecStart=/bin/true\n' > "${job1}.service"
printf 'weekly | true\nmonthly | true\n' > "${job_dir}/appmo-schedule"
sync_scheduled_jobs job "${job_dir}"
check "jobs: other app's unit kept" "ExecStart=/bin/true" "$(grep '^ExecStart=' "${job1}.service")"
check "jobs: next name used"        "appmotel-job.job-2" "$(paste -sd' ' "${APPS_CONFIG_DIR}/job/jobs.list")"
remove_scheduled_jobs job
check "jobs: removed"               "1|no|no" "$(find "${SYSTEMD_USER_DIR}" -name 'appmotel-job.job-*' | wc -l)|$([[ -f "${APPS_CONFIG_DIR}/job/jobs.list" ]] && echo yes || echo no)|$([[ -d "${APPS_CONFIG_DIR}/job/jobs" ]] && echo yes || echo no)"
rm -f "${job_dir}/appmo-schedule"
sync_scheduled_jobs job "${job_dir}"
check "jobs: no file, no jobs"      "no" "$([[ -f "${APPS_CONFIG_DIR}/job/jobs.list" ]] && echo yes || echo no)"

# --- restore_backup: deps of a subfolder app, reset-failed before start,
#     jobs rebuilt also when the restore fails
systemctl() { local IFS=' '; echo "systemctl $*" >> "${ops}/restore.log"; }
deps_fail=false
setup_python_env() { echo "python $1" >> "${ops}/deps.log"; [[ "${deps_fail}" == "false" ]]; }
setup_nodejs_env() { echo "node $1" >> "${ops}/deps.log"; }
setup_go_env() { echo "go $1" >> "${ops}/deps.log"; }
setup_zensical_env() { echo "zensical $1" >> "${ops}/deps.log"; }
sync_scheduled_jobs() { echo "jobs $2" >> "${ops}/restore.log"; }
rs_repo="${APPS_DATA_DIR}/rs/repo"
mkdir -p "${rs_repo}/web" "${APPS_CONFIG_DIR}/rs"
echo flask > "${rs_repo}/web/requirements.txt"
printf 'APP_NAME="rs"\nPORT="12003"\nSUBDIR="web"\n' > "${APPS_CONFIG_DIR}/rs/metadata.conf"
echo 'PORT=12003' > "${APPS_CONFIG_DIR}/rs/.env"
printf '[Service]\nExecStart=/bin/true\n' > "${SYSTEMD_USER_DIR}/appmotel-rs.service"
rs_id=$(create_backup rs)
: > "${ops}/restore.log"; : > "${ops}/deps.log"
check "restore: succeeds"              "0" "$(restore_backup rs "${rs_id}" >/dev/null 2>&1; echo $?)"
check "restore: deps in subfolder"     "python ${rs_repo}/web" "$(grep '^python' "${ops}/deps.log")"
check "restore: jobs from subfolder"   "jobs ${rs_repo}/web" "$(grep '^jobs' "${ops}/restore.log")"
check "restore: reset-failed, start"   "reset-failed|start" \
  "$(grep -oE 'systemctl --user (reset-failed|start) appmotel-rs$' "${ops}/restore.log" | awk '{print $3}' | paste -sd'|')"
deps_fail=true
: > "${ops}/restore.log"
check "restore: dep failure -> 1"      "1" "$(restore_backup rs "${rs_id}" >/dev/null 2>&1; echo $?)"
check "restore: jobs after failure"    "1" "$(grep -c '^jobs' "${ops}/restore.log")"
check "restore: no start after failure" "0" "$(grep -c 'start appmotel-rs$' "${ops}/restore.log")"
unset -f systemctl setup_python_env setup_nodejs_env setup_go_env setup_zensical_env sync_scheduled_jobs

# --- Procfile apps: processes are units, not components
svc() { local -a s=(); get_all_services "$1" s; local IFS=' '; echo "${s[*]}"; }
mkdir -p "${APPS_DATA_DIR}/pf/repo"
printf 'web: python3 app.py\nworker: python3 worker.py\n' > "${APPS_DATA_DIR}/pf/repo/Procfile"
save_app_metadata pf https://github.com/u/pf main 12004 "" "" "web worker" 2>/dev/null
check "procfile: PROCESSES saved"   'PROCESSES="web worker"' "$(grep '^PROCESSES=' "${APPS_CONFIG_DIR}/pf/metadata.conf")"
check "procfile: services"          "web worker" "$(svc pf)"
check "procfile: units"             "appmotel-pf-web.service appmotel-pf-worker.service" \
  "$(units=(); get_app_unit_files pf units; IFS=' '; echo "${units[*]}")"
check "procfile: not components"    "no" "$(is_multi_component pf && echo yes || echo no)"
save_app_metadata pf https://github.com/u/pf main 12004 "" "" "" 2>/dev/null
check "procfile: old app, from Procfile" "web worker" "$(svc pf)"
printf '[Service]\nExecStart=/bin/true\n' > "${SYSTEMD_USER_DIR}/appmotel-pf.service"
check "procfile: own unit wins"     "pf" "$(svc pf)"
rm -f "${SYSTEMD_USER_DIR}/appmotel-pf.service"
save_app_metadata mc https://github.com/u/mc main 12005 "backend frontend" "" "" 2>/dev/null
check "components: multi"           "yes|backend frontend" "$(is_multi_component mc && echo yes)|$(svc mc)"
save_app_metadata sub https://github.com/u/sub main 12006 "" "apps/x" "" 2>/dev/null
load_app_metadata sub; load_app_metadata mc
check "metadata: no stale SUBDIR"   "unset" "${SUBDIR:-unset}"

# --- cmd_logs: what it asks journalctl for
journalctl() { printf '%s\n' "$@"; }
require_app_exists() { :; }
mkdir -p "${APPS_CONFIG_DIR}/lg"; printf 'APP_NAME="lg"\n' > "${APPS_CONFIG_DIR}/lg/metadata.conf"
check "logs: default 50"      "1" "$(cmd_logs lg | grep -c '^50$')"
check "logs: lines"           "20|--follow" "$(cmd_logs lg 20 -f | grep -A1 '^-n$' | tail -n 1)|$(cmd_logs lg 20 -f | tail -n 1)"
check "logs: since, no -n"    "--since=1h ago|0" "$(cmd_logs lg --since '1h ago' | grep '^--since')|$(cmd_logs lg --since '1h ago' | grep -c '^-n$')"
check "logs: grep as one arg" "--grep=a|b" "$(cmd_logs lg --grep 'a|b' | grep '^--grep')"
check "logs: bad option"      "DIE" "$( (cmd_logs lg --bogus) | cut -c1-3)"
check "logs: bad lines"       "DIE" "$( (cmd_logs lg -n x) | cut -c1-3)"
unset -f journalctl require_app_exists

# --- list_tls_certs: Let's Encrypt certificates from acme.json, files from tls-config.yaml
openssl req -x509 -newkey rsa:2048 -nodes -days 3 -subj "/CN=app1.example.org" \
  -addext "subjectAltName=DNS:app1.example.org,DNS:www.example.org" \
  -keyout "${ops}/le.key" -out "${ops}/le.pem" 2>/dev/null
printf '{"letsencrypt": {"Account": {}, "Certificates": [{"domain": {"main": "app1.example.org", "sans": ["www.example.org"]}, "certificate": "%s", "key": "x", "Store": "default"}]}}\n' \
  "$(base64 -w0 < "${ops}/le.pem")" > "${ops}/acme.json"
row=$(list_tls_certs "${ops}/acme.json")
check "certs: acme names"   "letsencrypt|app1.example.org,www.example.org" "$(cut -f1,2 <<< "${row}" | tr '\t' '|')"
left=$(( $(cut -f3 <<< "${row}") - $(date +%s) ))
check "certs: acme expiry"  "yes" "$([[ ${left} -gt 172800 && ${left} -le 259300 ]] && echo yes)"
printf 'tls:\n  certificates:\n    - certFile: %s\n      keyFile: %s\n' "${ops}/le.pem" "${ops}/le.key" > "${TRAEFIK_DYNAMIC_DIR}/tls-config.yaml"
check "certs: file too"     "file|app1.example.org,www.example.org" "$(list_tls_certs "${ops}/acme.json" | head -n 1 | cut -f1,2 | tr '\t' '|')"
echo '{}' > "${ops}/empty.json"; rm -f "${TRAEFIK_DYNAMIC_DIR}/tls-config.yaml"
check "certs: none"         "" "$(list_tls_certs "${ops}/empty.json")"

echo
if [[ ${failures} -gt 0 ]]; then
  echo "${failures} check(s) failed"
  exit 1
fi
echo "all checks passed"
