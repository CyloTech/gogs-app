#!/usr/bin/env bash
# Tests for the Appbox installed callback, run against a local mock API (needs
# bash, curl and python3, and GNU sed or gsed for the upgrade cases; no
# Docker):
#   - appbox-installed-callback retries network errors, 408, 429 and 5xx,
#     stops after one try on any other status, sends CALLBACK_TOKEN in
#     X-Cylo-Callback-Token, passes an optional JSON body and never logs the
#     callback token carried in INSTANCE_ID;
#   - entrypoint.sh execs Gogs straight away even when the API rejects the
#     callback, sends a pending callback once in the background, clears the
#     pending flag, traces none of its commands and keeps the callback token
#     and the admin password out of its output;
#   - a fresh install creates the admin user from ADMIN_USER, ADMIN_PASS and
#     ADMIN_EMAIL, and refuses to start (no callback, no markers, no files)
#     when any of them is missing or empty; an update does not need them.
#
# Usage: tests/test-installed-callback.sh
set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="${repo_root}/appbox-installed-callback"
token_id='999?callback_token=querytoken0123456789'
header_token='headertoken0123456789'
admin_password='gatepassword0123456789'
admin_env=(ADMIN_USER=gateadmin "ADMIN_PASS=${admin_password}" ADMIN_EMAIL=gate@example.test)

# Answers GET with 200 (readiness) and each POST with the next status from a
# comma-separated list, logging what it received.
mock_server='
import http.server, json, os, sys
port, codes, log = int(sys.argv[1]), [int(c) for c in sys.argv[2].split(",")], sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
    def do_POST(self):
        seen = sum(1 for _ in open(log)) if os.path.exists(log) else 0
        code = codes[min(seen, len(codes) - 1)]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "code": code, "body": body,
                                "token": self.headers.get("X-Cylo-Callback-Token", "")}) + "\n")
        self.send_response(code)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'

failures=0
work=""
server=""

pass() { echo "ok   $*"; }
fail() {
    echo "FAIL $*"
    [[ -f "${work}/output" ]] && sed 's/^/     /' "${work}/output"
    failures=$((failures + 1))
}

start_mock() {
    work="$(mktemp -d)"
    port=$((20000 + RANDOM % 20000))
    python3 -c "${mock_server}" "${port}" "$1" "${work}/requests" &
    server=$!
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:${port}/" && return 0
        sleep 0.1
    done
    echo "mock API did not start" >&2
    exit 2
}

stop_mock() {
    kill "${server}" 2>/dev/null
    wait "${server}" 2>/dev/null
    rm -rf "${work}"
}

# Run a command, killing it (exit 124) if it is still running after $1 seconds,
# so a callback that never stops fails the test instead of hanging it.
run_limited() {
    local limit=$1 pid ticks=0
    shift
    "$@" &
    pid=$!
    while kill -0 "${pid}" 2>/dev/null && [[ "${ticks}" -lt $((limit * 10)) ]]; do
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null
        wait "${pid}" 2>/dev/null
        return 124
    fi
    wait "${pid}"
}

request_count() { cat "${work}/requests" 2>/dev/null | wc -l | tr -d ' '; }
token_logged() { grep -cE 'querytoken|headertoken|gatepassword' "${work}/output"; }
traced() { grep -c '^+' "${work}/output"; }

# --- helper ------------------------------------------------------------------

helper_case() {
    local codes=$1 want_exit=$2 want_requests=$3
    shift 3
    start_mock "${codes}"
    run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 \
        "$@" "${helper}" >"${work}/output" 2>&1
    local rc=$? requests leaked
    requests=$(request_count)
    leaked=$(token_logged)
    if [[ "${rc}" == "${want_exit}" && "${requests}" == "${want_requests}" && "${leaked}" == 0 ]]; then
        pass "helper codes=${codes} exit=${rc} requests=${requests}"
    else
        fail "helper codes=${codes} exit=${rc}/${want_exit} requests=${requests}/${want_requests} token_logged=${leaked}"
    fi
    stop_mock
}

helper_case 200 0 1
helper_case 401 1 1
helper_case 404 1 1
helper_case 409 1 1
helper_case 422 1 1
helper_case 503,502,200 0 3
helper_case 429,408,204 0 3
helper_case 500,401 1 2
helper_case 200 0 0 SKIP_APPBOX_CALLBACK=1

# Network errors are retried: nothing listens on the port for the first try.
work="$(mktemp -d)"
port=$((20000 + RANDOM % 20000))
(
    sleep 1.5
    exec python3 -c "${mock_server}" "${port}" 200 "${work}/requests"
) &
server=$!
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY=1 "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'HTTP 000, retrying' "${work}/output" && [[ "$(request_count)" == 1 ]]; then
    pass "helper retries a network error"
else
    fail "helper network error exit=${rc} requests=$(request_count)"
fi
stop_mock

# An invalid APPBOX_CALLBACK_RETRY_DELAY falls back to the 5s default.
start_mock 503,200
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY='1;x' "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'retrying in 5s' "${work}/output" && [[ "$(request_count)" == 2 ]]; then
    pass "helper ignores an invalid retry delay"
else
    fail "helper invalid retry delay exit=${rc} requests=$(request_count)"
fi
stop_mock

# Token header, query string and optional body reach the API.
start_mock 200
run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
    APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    "${helper}" '{"custom_fields":[{"key":"ADMIN_PANEL","value":"https://example.test/"}]}' \
    >"${work}/output" 2>&1
if python3 - "${work}/requests" "${header_token}" <<'PY'
import json, sys
req = json.loads(open(sys.argv[1]).readline())
assert req["path"] == "/v1/apps/installed/999?callback_token=querytoken0123456789", req
assert req["token"] == sys.argv[2], req
assert json.loads(req["body"])["custom_fields"][0]["key"] == "ADMIN_PANEL", req
PY
then
    pass "helper sends path, X-Cylo-Callback-Token and body"
else
    fail "helper request contents"
fi
stop_mock


# --- entrypoint ----------------------------------------------------------------

# Start a sandboxed entrypoint with a fake app as CMD that records when it
# started, wait for the background callback to finish, then check that the app
# started within 2s, the expected number of POSTs arrived, the pending flag
# (${work}/callback_pending) is gone and no token was logged.
#   run_sandboxed_entrypoint <sandbox> <label> <want_requests> [VAR=value...]
run_sandboxed_entrypoint() {
    local sandbox=$1 label=$2 want_requests=$3
    shift 3
    chmod +x "${sandbox}"
    local started_at app_at entrypoint_pid waited=0
    started_at=$(date +%s)
    env -u ADMIN_USER -u ADMIN_PASS -u ADMIN_EMAIL \
        INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 "$@" \
        "${sandbox}" bash -c "date +%s >'${work}/app_started'; sleep 1" \
        >"${work}/output" 2>&1 </dev/null &
    entrypoint_pid=$!

    # A callback that blocks startup never reaches the app; give up after 10s.
    while [[ ! -f "${work}/app_started" && "${waited}" -lt 10 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [[ ! -f "${work}/app_started" ]]; then
        pkill -P "${entrypoint_pid}" 2>/dev/null
        kill "${entrypoint_pid}" 2>/dev/null
    fi
    wait "${entrypoint_pid}" 2>/dev/null

    # The background sender outlives the fake app; wait for it to finish.
    waited=0
    while [[ -f "${work}/callback_pending" && "${waited}" -lt 20 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    sleep 0.5

    app_at=$(cat "${work}/app_started" 2>/dev/null || echo 0)
    local requests leaked trace_lines
    requests=$(request_count)
    leaked=$(token_logged)
    trace_lines=$(traced)
    if [[ "${app_at}" -gt 0 && $((app_at - started_at)) -le 2 && ! -f "${work}/callback_pending" \
        && "${requests}" == "${want_requests}" && "${leaked}" == 0 && "${trace_lines}" == 0 ]]; then
        pass "${label}: app started after $((app_at - started_at))s, requests=${requests}"
    else
        fail "${label}: app_started=${app_at} start=${started_at} pending=$([[ -f "${work}/callback_pending" ]] && echo yes || echo no) requests=${requests}/${want_requests} secret_logged=${leaked} traced=${trace_lines}"
    fi
}

# On first boot the pending flag must be set before the configured marker, so
# a crash between the two cannot lose the callback.
#   flag_order_check <pending flag touch regex> <configured marker touch regex>
flag_order_check() {
    local pending marker
    pending=$(grep -nE "$1" "${entrypoint}" | head -1 | cut -d: -f1)
    marker=$(grep -nE "$2" "${entrypoint}" | head -1 | cut -d: -f1)
    if [[ -n "${pending}" && -n "${marker}" && "${pending}" -lt "${marker}" ]]; then
        pass "first boot marks the callback pending before the configured marker"
    else
        fail "first boot: pending flag line=${pending:-none}, configured marker line=${marker:-none}"
    fi
}

entrypoint="${repo_root}/entrypoint.sh"

# The upgrade path edits app.ini with GNU `sed -i`; use gsed where sed is BSD.
gnu_sed_dir=""
if ! sed --version 2>/dev/null | grep -q GNU && command -v gsed >/dev/null; then
    gnu_sed_dir="$(mktemp -d)"
    ln -s "$(command -v gsed)" "${gnu_sed_dir}/sed"
fi

# Write a copy of entrypoint.sh to ${work}/entrypoint.sh with /home/git, the
# marker, flag, helper and local URL pointed into the scratch directory, chown
# disabled and gosu removed from the final exec. Fails if the final exec could
# not be rewritten.
make_sandbox() {
    sed -e "s|/home/git|${work}/home/git|g" \
        -e "s|^CONFIG_FLAG=.*|CONFIG_FLAG=\"${work}/app_configured\"|" \
        -e "s|^LOCAL_URL=.*|LOCAL_URL=\"http://127.0.0.1:${port}\"|" \
        -e "s|^CALLBACK_PENDING_FLAG=.*|CALLBACK_PENDING_FLAG=\"${work}/callback_pending\"|" \
        -e "s|^CALLBACK_HELPER=.*|CALLBACK_HELPER=\"${helper}\"|" \
        -e 's|^chown -R 1000:1000 |: chown -R 1000:1000 |' \
        -e 's|^\( *\)chown 1000:1000 |\1: chown 1000:1000 |' \
        -e 's|^exec gosu "${APP_USER}" "$@"$|exec "$@"|' \
        "${entrypoint}" >"${work}/entrypoint.sh"
    chmod +x "${work}/entrypoint.sh"
    grep -q '^exec "\$@"$' "${work}/entrypoint.sh"
}

# Stubs for a first start: gosu drops its user argument, and the gogs binary
# records its arguments in ${work}/gogs_args.
fresh_stubs() {
    mkdir -p "${work}/bin" "${work}/home/git/gogs"
    printf '#!/bin/bash\nshift\nexec "$@"\n' >"${work}/bin/gosu"
    printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"%s/gogs_args"\n' "${work}" >"${work}/home/git/gogs/gogs"
    chmod +x "${work}/bin/gosu" "${work}/home/git/gogs/gogs"
}

# Run the sandboxed entrypoint on an existing install.
#   state: upgrade (no /etc/app_configured, app.ini present), upgrade-no-admin
#   (the same without ADMIN_USER, ADMIN_PASS and ADMIN_EMAIL),
#   restart-pending (marker and pending flag present) or restart (marker only).
entrypoint_case() {
    local state=$1 codes=$2 want_requests=$3
    start_mock "${codes}"
    mkdir -p "${work}/home/git/gogs/custom/conf"
    if ! make_sandbox; then
        fail "entrypoint ${state}: could not sandbox the final exec"
        stop_mock
        return
    fi
    printf '[server]\nHTTP_PORT = 80\nSSH_PORT = 22\n' >"${work}/home/git/gogs/custom/conf/app.ini"
    local install_env=("${admin_env[@]}")
    case "${state}" in
        upgrade-no-admin) install_env=() ;;
        restart-pending) touch "${work}/app_configured" "${work}/callback_pending" ;;
        restart) touch "${work}/app_configured" ;;
    esac
    run_sandboxed_entrypoint "${work}/entrypoint.sh" "entrypoint ${state} codes=${codes}" "${want_requests}" \
        ${install_env[@]+"${install_env[@]}"} PATH="${gnu_sed_dir:+${gnu_sed_dir}:}${PATH}"
    [[ -f "${work}/app_configured" ]] || fail "entrypoint ${state}: /etc/app_configured was not created"
    stop_mock
}

# A first start with no app.ini writes app.ini, creates the admin user from
# the install values and execs Gogs; the password reaches the gogs binary but
# never the output.
fresh_case() {
    local codes=$1 want_requests=$2
    start_mock "${codes}"
    fresh_stubs
    if ! make_sandbox; then
        fail "entrypoint fresh: could not sandbox the final exec"
        stop_mock
        return
    fi
    run_sandboxed_entrypoint "${work}/entrypoint.sh" "entrypoint fresh codes=${codes}" "${want_requests}" \
        "${admin_env[@]}" PATH="${work}/bin:${PATH}"
    local expected
    expected=$(printf '%s\n' admin create-user --name gateadmin --password "${admin_password}" \
        --admin --email gate@example.test)
    if grep -q '^INSTALL_LOCK = true$' "${work}/home/git/gogs/custom/conf/app.ini" 2>/dev/null \
        && [[ -f "${work}/app_configured" && "$(cat "${work}/gogs_args" 2>/dev/null)" == "${expected}" ]]; then
        pass "entrypoint fresh: app.ini written, admin user created from the install values"
    else
        fail "entrypoint fresh: app.ini, marker or create-user arguments"
    fi
    stop_mock
}

# Without one of the install values, a first start stops before setting
# anything up: Gogs does not start, nothing is sent, and no marker, flag,
# directory or app.ini is created.
#   refused_case <variable> unset|empty
refused_case() {
    local name=$1 mode=$2 vars=() var
    start_mock 200
    fresh_stubs
    if ! make_sandbox; then
        fail "entrypoint with ${name} ${mode}: could not sandbox the final exec"
        stop_mock
        return
    fi
    for var in "${admin_env[@]}"; do
        if [[ "${var%%=*}" != "${name}" ]]; then
            vars+=("${var}")
        elif [[ "${mode}" == empty ]]; then
            vars+=("${name}=")
        fi
    done
    run_limited 10 env -u ADMIN_USER -u ADMIN_PASS -u ADMIN_EMAIL \
        INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" "${vars[@]}" PATH="${work}/bin:${PATH}" \
        "${work}/entrypoint.sh" bash -c "date +%s >'${work}/app_started'" >"${work}/output" 2>&1 </dev/null
    local rc=$?
    sleep 1
    if [[ "${rc}" != 0 && "${rc}" != 124 && ! -f "${work}/app_started" && ! -f "${work}/callback_pending" \
        && ! -f "${work}/app_configured" && ! -e "${work}/home/git/gogs/custom" && ! -f "${work}/gogs_args" \
        && "$(request_count)" == 0 && "$(token_logged)" == 0 ]] \
        && grep -q "^${name} is empty; refusing to set up Gogs" "${work}/output"; then
        pass "entrypoint with ${name} ${mode}: exit ${rc}, Gogs not started, no callback, nothing written"
    else
        fail "entrypoint with ${name} ${mode}: exit=${rc} app_started=$([[ -f "${work}/app_started" ]] && echo yes || echo no) requests=$(request_count)"
    fi
    stop_mock
}

if sed --version 2>/dev/null | grep -q GNU || [[ -n "${gnu_sed_dir}" ]]; then
    entrypoint_case upgrade 200 1
    entrypoint_case upgrade 401 1
    entrypoint_case upgrade 403 1
    entrypoint_case upgrade-no-admin 200 1
else
    echo "skip entrypoint upgrade cases: GNU sed (or gsed) is not installed"
fi
entrypoint_case restart-pending 503,200 2
entrypoint_case restart 200 0
fresh_case 200 1
fresh_case 401 1
for name in ADMIN_USER ADMIN_PASS ADMIN_EMAIL; do
    refused_case "${name}" unset
    refused_case "${name}" empty
done
[[ -n "${gnu_sed_dir}" ]] && rm -rf "${gnu_sed_dir}"

if grep -q 'apps/installed' "${entrypoint}"; then
    fail "entrypoint.sh still calls the installed callback itself"
else
    pass "entrypoint.sh leaves the callback to the background helper"
fi
if grep -qE '^[[:space:]]*set -[a-z]*x' "${entrypoint}"; then
    fail "entrypoint.sh turns on command tracing"
else
    pass "entrypoint.sh does not trace its commands"
fi
if grep -qE 'ADMIN_(USER|PASS|EMAIL):-' "${entrypoint}"; then
    fail "entrypoint.sh has a default for an install value"
else
    pass "entrypoint.sh has no defaults for the install values"
fi
flag_order_check '^ *touch "\$\{CALLBACK_PENDING_FLAG\}"$' '^ *touch "\$\{CONFIG_FLAG\}"$'

exit "${failures}"
