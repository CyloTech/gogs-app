#!/usr/bin/env python3
"""Release gate for repo.cylo.net/gogs:0.14.2-1. Run it on the builder.

Usage: release/release-gate.py repo.cylo.net/gogs:0.14.2-1

Exits 0 only when the exact local image passes every check below and the
authenticated registry reports the tag definitively absent:

- tests/test-installed-callback.sh (callback helper and sandboxed entrypoint);
- image: Ubuntu 24.04, Gogs 0.14.2, no ADMIN_* values in its configuration,
  the committed entrypoint, moduser.sh and callback helper, and an entrypoint
  that does not turn on command tracing;
- ADMIN_PASS missing or empty, ADMIN_USER empty, ADMIN_EMAIL missing: the
  container exits non-zero, writes nothing to its volumes or markers and
  sends no installed callback;
- fresh install with dummy values: API and web logins work with the install
  password and a wrong password is refused, registration stays disabled,
  app.ini carries the domain, SSH port and site URL, Gogs runs as UID 1000
  and answers SSH, a repository can be created and cloned, one installed
  callback with the token header, and the password is in neither
  `docker logs` nor the volumes or the log directory;
- restart: logins still work, no second callback, nothing secret logged;
- upgrade from gogs:0.14.2 on the same volumes: the admin and a second user
  can still log in, the repository and its files are kept, one callback,
  nothing secret logged or stored, and a restart works;
- upgrade from gogs:latest (Gogs 0.13.2, which kept app.ini inside the
  container and has no custom volume) onto its data and repository volumes
  plus a new empty custom volume, as the 0.14.2-1 catalogue version mounts
  them: the same checks, and registration is now disabled.

The installed callback goes to a local HTTPS mock that answers as
api.cylo.io/api.cylo.net on a private Docker network; the containers trust a
throwaway CA added to their CA bundle. Nothing is sent to the real API.
"""
import base64
import hashlib
import http.cookiejar
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

spec = importlib.util.spec_from_file_location('registry_check', Path(__file__).with_name('registry-check.py'))
registry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registry)
if len(sys.argv) != 2 or sys.argv[1] != registry.EXPECTED:
    raise SystemExit('Usage: release-gate.py ' + registry.EXPECTED)
image = sys.argv[1]
repo_root = Path(__file__).resolve().parent.parent
run_id = 'gogs-gate-' + uuid.uuid4().hex[:10]
work = Path(tempfile.mkdtemp(prefix=run_id + '-'))
label = 'appbox.release-gate=' + run_id
network = run_id + '-net'
containers = []
volumes = []
networks = []
# Dummy install values (the form only allows letters and digits in the user
# name and password checks).
user = 'gateadmin'
email = 'gate@example.test'
second_user = 'gatesecond'
password = 'gate' + secrets.token_hex(8)
upgrade_password = 'gate' + secrets.token_hex(8)
second_password = 'gate' + secrets.token_hex(8)
callback_token = 'gatetoken' + secrets.token_hex(12)
secret_values = (password, upgrade_password, second_password, callback_token)
instance_id = '900000111'
domain = 'gogs.gate.test'
root_url = 'https://gogs.gate.test/'
ssh_port = '40022'
# Volume mount points, as the catalogue binds them.
CUSTOM = '/home/git/gogs/custom'
DATA = '/home/git/gogs/data'
REPOS = '/home/git/repositories'
LOGDIR = '/home/git/gogs/log'

MOCK = r'''
import http.server, json, ssl
class Handler(http.server.BaseHTTPRequestHandler):
    def handle_one(self, method):
        length = int(self.headers.get('Content-Length') or 0)
        if length:
            self.rfile.read(length)
        auth = self.headers.get('Authorization') or ''
        print(json.dumps({'method': method, 'host': self.headers.get('Host'), 'path': self.path,
                          'token': self.headers.get('X-Cylo-Callback-Token'),
                          'bearer': auth.startswith('Bearer ')}), flush=True)
        ok = method == 'POST' and self.path.startswith('/v1/apps/installed/')
        body = b'{"status":"success"}' if ok else b'{}'
        self.send_response(200 if ok else 404)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.handle_one('POST')
    def do_GET(self):
        self.handle_one('GET')
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('0.0.0.0', 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain('/mock/server.crt', '/mock/server.key')
server.socket = context.wrap_socket(server.socket, server_side=True)
print('READY', flush=True)
server.serve_forever()
'''


def redact(text):
    for value in secret_values:
        text = text.replace(value, '[redacted]')
    return text


def command(args, timeout=300, check=True):
    p = subprocess.run(args, capture_output=True, timeout=timeout)
    if check and p.returncode:
        # Never print the arguments: they carry the dummy passwords.
        raise RuntimeError('Builder command failed: ' + redact(p.stderr.decode(errors='replace')[-1500:]))
    return p


def out(args, timeout=300):
    return command(args, timeout).stdout.decode()


def logs(name):
    p = command(['docker', 'logs', name], check=False)
    return p.stdout.decode(errors='replace') + p.stderr.decode(errors='replace')


def show_logs(name):
    print('--- last log lines of ' + name, flush=True)
    print(redact(logs(name))[-4000:], flush=True)


def make_tls():
    mock = work / 'mock'
    mock.mkdir()
    (mock / 'mock.py').write_text(MOCK)
    (work / 'ext.cnf').write_text('subjectAltName=DNS:api.cylo.io,DNS:api.cylo.net\nextendedKeyUsage=serverAuth\n')
    command(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
             '-keyout', str(work / 'ca.key'), '-out', str(work / 'ca.crt'), '-subj', '/CN=' + run_id + ' CA',
             '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign'])
    command(['openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(mock / 'server.key'),
             '-out', str(work / 'server.csr'), '-subj', '/CN=api.cylo.io'])
    command(['openssl', 'x509', '-req', '-in', str(work / 'server.csr'), '-CA', str(work / 'ca.crt'),
             '-CAkey', str(work / 'ca.key'), '-CAcreateserial', '-days', '2',
             '-extfile', str(work / 'ext.cnf'), '-out', str(mock / 'server.crt')])
    for name, selected in (('ca-bundle.crt', image), ('ca-bundle-legacy.crt', registry.LEGACY)):
        bundle = out(['docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'cat', selected,
                      '/etc/ssl/certs/ca-certificates.crt'])
        (work / name).write_text(bundle + (work / 'ca.crt').read_text())
    for path in [work, mock] + list(mock.iterdir()) + [work / 'ca-bundle.crt', work / 'ca-bundle-legacy.crt']:
        os.chmod(path, 0o755 if path.is_dir() else 0o644)


def start_mock():
    command(['docker', 'network', 'create', '--label', label, network])
    networks.append(network)
    name = run_id + '-mock'
    command(['docker', 'run', '-d', '--name', name, '--label', label, '--network', network,
             '--network-alias', 'api.cylo.io', '--network-alias', 'api.cylo.net',
             '-v', str(work / 'mock') + ':/mock:ro', '--entrypoint', 'python3', registry.CURRENT, '/mock/mock.py'])
    containers.append(name)
    for _ in range(60):
        if 'READY' in logs(name):
            return name
        time.sleep(1)
    show_logs(name)
    raise RuntimeError('Mock API did not start')


def callbacks(mock):
    found = []
    for line in logs(mock).splitlines():
        if line.startswith('{'):
            record = json.loads(line)
            if record['method'] == 'POST' and record['path'] == '/v1/apps/installed/' + instance_id:
                found.append(record)
    return found


def wait_callbacks(mock, count, limit=90):
    for _ in range(limit):
        if len(callbacks(mock)) >= count:
            break
        time.sleep(1)
    time.sleep(3)
    found = callbacks(mock)
    assert len(found) == count, 'expected %d installed callbacks, got %d' % (count, len(found))
    return found


def new_volume(suffix):
    name = run_id + '-' + suffix
    command(['docker', 'volume', 'create', '--label', label, name])
    volumes.append(name)
    return name


def install_env(admin_password, omit=(), empty=()):
    values = {'ADMIN_USER': user, 'ADMIN_PASS': admin_password, 'ADMIN_EMAIL': email}
    env = []
    for key, value in values.items():
        if key in omit:
            continue
        env.append('%s=%s' % (key, '' if key in empty else value))
    return env


def launch(suffix, selected, mounts, env, legacy=False):
    """Start a container the way the catalogue version would.

    0.14.2 and 0.14.2-1 run without --init and get VIRTUAL_PORT=3000;
    0.13.2 runs with --init and listens on port 80 (the image's HTTP_PORT).
    mounts maps volume names to mount points; nocopy keeps them empty like
    the host directories Appbox binds in.
    """
    name = run_id + '-' + suffix
    args = ['docker', 'run', '-d', '--platform', 'linux/amd64', '--name', name, '--label', label,
            '--network', network, '-p', '127.0.0.1::' + ('80' if legacy else '3000'), '-p', '127.0.0.1::10022']
    if legacy:
        args += ['--init', '-v', str(work / 'ca-bundle-legacy.crt') + ':/etc/ssl/certs/ca-certificates.crt:ro']
    else:
        args += ['-v', str(work / 'ca-bundle.crt') + ':/etc/ssl/certs/ca-certificates.crt:ro',
                 '-e', 'VIRTUAL_PORT=3000']
    for volume, target in mounts.items():
        args += ['-v', volume + ':' + target + ':nocopy']
    args += ['-e', 'SSH_PORT=' + ssh_port, '-e', 'DOMAIN=' + domain, '-e', 'ROOT_URL=' + root_url,
             '-e', 'INSTANCE_ID=' + instance_id, '-e', 'CALLBACK_TOKEN=' + callback_token]
    for item in env:
        args += ['-e', item]
    command(args + [selected])
    containers.append(name)
    return name


def host_port(name, port):
    binding = out(['docker', 'port', name, port + '/tcp']).strip().splitlines()[0]
    return int(binding.rsplit(':', 1)[1])


def base_url(name, legacy=False):
    return 'http://127.0.0.1:%d' % host_port(name, '80' if legacy else '3000')


def api(base, path, username=None, user_password=None, body=None, method=None):
    headers = {'Accept': 'application/json'}
    if username is not None:
        token = base64.b64encode(('%s:%s' % (username, user_password)).encode()).decode()
        headers['Authorization'] = 'Basic ' + token
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers['Content-Type'] = 'application/json'
    request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.status, response.read().decode(errors='replace')
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode(errors='replace')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def web_login(base, username, user_password):
    """Sign in through the login form. True when Gogs redirects away from it."""
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), NoRedirect)
    page = opener.open(base + '/user/login', timeout=20).read().decode(errors='replace')
    match = re.search(r'name="_csrf" value="([^"]+)"', page)
    assert match, 'no CSRF token on the login page'
    form = urllib.parse.urlencode({'_csrf': match.group(1), 'user_name': username,
                                   'password': user_password}).encode()
    try:
        opener.open(base + '/user/login', data=form, timeout=20)
        return False
    except urllib.error.HTTPError as error:
        if error.code in (302, 303):
            return '/user/login' not in (error.headers.get('Location') or '')
        raise


def api_login(base, username, user_password):
    status, body = api(base, '/api/v1/user', username, user_password)
    if status != 200:
        return False
    return json.loads(body).get('username') == username


def wait_login(name, username, user_password, legacy=False, limit=300):
    last = ''
    for _ in range(limit // 3):
        state = out(['docker', 'inspect', '--format', '{{.State.Running}}', name]).strip()
        if state != 'true':
            show_logs(name)
            raise RuntimeError(name + ' stopped')
        try:
            if api_login(base_url(name, legacy), username, user_password):
                return
            last = 'login refused'
        except (OSError, ValueError) as error:
            last = type(error).__name__
        time.sleep(3)
    show_logs(name)
    raise RuntimeError('Login did not succeed: ' + last)


def check_logins(name, username, user_password, wrong_password):
    base = base_url(name)
    assert api_login(base, username, user_password), 'API login failed for ' + username
    assert web_login(base, username, user_password), 'web login failed for ' + username
    assert not api_login(base, username, wrong_password), 'wrong password accepted by the API'
    assert not web_login(base, username, wrong_password), 'wrong password accepted by the login form'


def create_repo(name, repo, username, user_password, legacy=False):
    base = base_url(name, legacy)
    status, body = api(base, '/api/v1/user/repos', username, user_password,
                       {'name': repo, 'description': 'Gate ' + repo, 'auto_init': True, 'readme': 'Default',
                        'private': False})
    assert status == 201, 'repository not created: HTTP %d %s' % (status, redact(body)[:300])


def create_second_user(name, admin_password, legacy=False):
    base = base_url(name, legacy)
    status, body = api(base, '/api/v1/admin/users', user, admin_password,
                       {'username': second_user, 'email': 'second@example.test', 'password': second_password,
                        'send_notify': False, 'source_id': 0, 'login_name': ''})
    assert status == 201, 'second user not created: HTTP %d %s' % (status, redact(body)[:300])


def check_repo(name, repo, username, user_password):
    base = base_url(name)
    status, body = api(base, '/api/v1/repos/%s/%s/raw/master/README.md' % (user, repo), username, user_password)
    assert status == 200 and repo in body, 'README of %s not readable: HTTP %d' % (repo, status)
    target = work / ('clone-' + name + '-' + repo)
    command(['git', 'clone', '--quiet', '--depth', '1', '%s/%s/%s.git' % (base, user, repo), str(target)],
            timeout=120)
    assert repo in (target / 'README.md').read_text(), 'cloned README of %s is wrong' % repo
    shutil.rmtree(target)


def check_config(name):
    ini = out(['docker', 'exec', name, 'cat', CUSTOM + '/conf/app.ini'])
    for pattern in (r'^DOMAIN\s*=\s*' + re.escape(domain) + r'$',
                    r'^EXTERNAL_URL\s*=\s*' + re.escape(root_url) + r'$',
                    r'^SSH_PORT\s*=\s*' + ssh_port + r'$',
                    r'^SSH_LISTEN_PORT\s*=\s*10022$',
                    r'^HTTP_PORT\s*=\s*3000$',
                    r'^DISABLE_REGISTRATION\s*=\s*true$',
                    r'^INSTALL_LOCK\s*=\s*true$'):
        assert re.search(pattern, ini, re.M), 'app.ini does not match ' + pattern
    # With registration disabled the page only says so; the form (and its
    # password confirmation field) is not shown.
    _, page = api(base_url(name), '/user/sign_up')
    assert 'name="retype"' not in page, 'sign-up form is offered'


def check_runtime(name):
    status = out(['docker', 'exec', name, 'cat', '/proc/1/status'])
    assert re.search(r'^Uid:\s+1000\s+1000\s+1000\s+1000$', status, re.M), 'Gogs is not UID 1000'
    assert 'gogs' in out(['docker', 'exec', name, 'cat', '/proc/1/comm']), 'PID 1 is not Gogs'
    with socket.create_connection(('127.0.0.1', host_port(name, '10022')), timeout=15) as conn:
        banner = conn.recv(256)
    assert banner.startswith(b'SSH-2.0-'), 'built-in SSH server did not answer'


def check_not_logged(name, values):
    text = logs(name)
    for value in values:
        assert value not in text, 'Secret found in the container log of ' + name
    assert not re.search(r'^\++ ', text, re.M), 'commands traced into the log of ' + name


def check_not_stored(name, values):
    for value in values:
        p = command(['docker', 'exec', name, 'grep', '-rlF', '-e', value, CUSTOM, DATA, REPOS, LOGDIR], check=False)
        assert p.returncode == 1, 'Password found in files of ' + name + ' (grep exit %d)' % p.returncode


def check_callback(found):
    assert found[-1]['host'] == 'api.cylo.net' and found[-1]['token'] == callback_token, 'callback without token'
    assert not found[-1]['bearer'], 'callback sent a Bearer header'


def refused(suffix, mock, env):
    before = len(callbacks(mock))
    mounts = {new_volume(suffix + '-custom'): CUSTOM, new_volume(suffix + '-data'): DATA,
              new_volume(suffix + '-repos'): REPOS}
    name = launch(suffix, image, mounts, env)
    status = command(['docker', 'wait', name], timeout=120).stdout.decode().strip()
    assert status not in ('', '0'), 'container exited with status ' + status
    assert 'refusing to set up Gogs' in logs(name), 'no refusal message'
    changed = out(['docker', 'diff', name])
    assert not re.search(r'^[AC] /etc/app(_configured|box_callback_pending)', changed, re.M), 'markers written'
    for volume in mounts:
        listing = out(['docker', 'run', '--rm', '--network', 'none', '-v', volume + ':/check',
                       '--entrypoint', 'find', image, '/check', '-mindepth', '1'])
        assert listing.strip() == '', 'files created in a volume'
    check_not_logged(name, secret_values)
    time.sleep(3)
    assert len(callbacks(mock)) == before, 'installed callback sent'
    print('PASS refused (%s): exit %s, nothing written, no callback' % (suffix, status), flush=True)


def upgrade(kind, mock, callbacks_seen):
    """Install the baseline, add data, stop it, start 0.14.2-1 on the same volumes."""
    legacy = kind == 'legacy'
    data_volume, repos_volume = new_volume(kind + '-data'), new_volume(kind + '-repos')
    custom_volume = new_volume(kind + '-custom')
    baseline_mounts = {data_volume: DATA, repos_volume: REPOS}
    if not legacy:
        baseline_mounts[custom_volume] = CUSTOM
    baseline_image = registry.LEGACY if legacy else registry.CURRENT
    baseline = launch('baseline-' + kind, baseline_image, baseline_mounts, install_env(upgrade_password),
                      legacy=legacy)
    wait_login(baseline, user, upgrade_password, legacy=legacy)
    callbacks_seen += 1
    wait_callbacks(mock, callbacks_seen)
    create_repo(baseline, 'gate-' + kind, user, upgrade_password, legacy=legacy)
    create_second_user(baseline, upgrade_password, legacy=legacy)
    baseline_leaked = upgrade_password in logs(baseline)
    command(['docker', 'stop', '--time', '30', baseline])

    upgraded = launch('upgraded-' + kind, image, {data_volume: DATA, repos_volume: REPOS, custom_volume: CUSTOM},
                      install_env(upgrade_password))
    wait_login(upgraded, user, upgrade_password)
    check_logins(upgraded, user, upgrade_password, password)
    check_logins(upgraded, second_user, second_password, upgrade_password)
    check_repo(upgraded, 'gate-' + kind, user, upgrade_password)
    check_config(upgraded)
    check_runtime(upgraded)
    callbacks_seen += 1
    check_callback(wait_callbacks(mock, callbacks_seen))
    check_not_logged(upgraded, secret_values)
    check_not_stored(upgraded, secret_values)
    command(['docker', 'restart', '--time', '30', upgraded])
    wait_login(upgraded, user, upgrade_password)
    check_logins(upgraded, second_user, second_password, upgrade_password)
    check_repo(upgraded, 'gate-' + kind, user, upgrade_password)
    wait_callbacks(mock, callbacks_seen, limit=5)
    check_not_logged(upgraded, secret_values)
    command(['docker', 'stop', '--time', '30', upgraded])
    path = 'fresh-install path (new custom volume)' if legacy else 'upgrade path'
    print('PASS upgrade from %s (%s): admin and second user log in, repository and files kept, registration '
          'disabled, one callback, nothing secret logged or stored, restart works (the baseline logged the '
          'password: %s)' % (kind, path, baseline_leaked), flush=True)
    return callbacks_seen


try:
    # --- unit tests and the image itself ----------------------------------------
    test = subprocess.run(['bash', str(repo_root / 'tests' / 'test-installed-callback.sh')],
                          capture_output=True, text=True, timeout=900)
    print(test.stdout[-4000:], flush=True)
    assert test.returncode == 0, 'tests/test-installed-callback.sh failed'
    details = json.loads(out(['docker', 'image', 'inspect', image]))[0]
    assert details['Architecture'] == 'amd64' and details['Os'] == 'linux'
    env = details['Config']['Env']
    assert not any(item.startswith('ADMIN_') for item in env), env
    assert details['Config']['Entrypoint'] == ['/entrypoint.sh'], details['Config']['Entrypoint']
    assert details['Config']['Cmd'] == ['/home/git/gogs/gogs', 'web'], details['Config']['Cmd']
    files = out(['docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'bash', image, '-c',
                 'sha256sum /entrypoint.sh /moduser.sh /usr/local/bin/appbox-installed-callback; '
                 '. /etc/os-release; echo "os-$ID-$VERSION_ID"; '
                 'bash -n /entrypoint.sh && echo syntax-ok; '
                 "grep -qE '^[[:space:]]*set -[a-z]*x' /entrypoint.sh || echo no-trace; "
                 '/home/git/gogs/gogs --version'])
    for path in ('entrypoint.sh', 'moduser.sh', 'appbox-installed-callback'):
        assert hashlib.sha256((repo_root / path).read_bytes()).hexdigest() in files, path + ' differs'
    for marker in ('os-ubuntu-24.04', 'syntax-ok', 'no-trace', 'Gogs version 0.14.2'):
        assert marker in files, files
    print('PASS image: Ubuntu 24.04, Gogs 0.14.2, no ADMIN_* defaults, committed scripts, no tracing', flush=True)

    make_tls()
    mock = start_mock()

    # --- missing install values: fail closed -------------------------------------
    refused('pass-unset', mock, install_env(password, omit=('ADMIN_PASS',)))
    refused('pass-empty', mock, install_env(password, empty=('ADMIN_PASS',)))
    refused('user-empty', mock, install_env(password, empty=('ADMIN_USER',)))
    refused('email-unset', mock, install_env(password, omit=('ADMIN_EMAIL',)))

    # --- fresh install --------------------------------------------------------------
    fresh = launch('fresh', image, {new_volume('fresh-custom'): CUSTOM, new_volume('fresh-data'): DATA,
                             new_volume('fresh-repos'): REPOS}, install_env(password))
    wait_login(fresh, user, password)
    check_logins(fresh, user, password, upgrade_password)
    check_config(fresh)
    check_runtime(fresh)
    create_repo(fresh, 'gate-fresh', user, password)
    check_repo(fresh, 'gate-fresh', user, password)
    check_callback(wait_callbacks(mock, 1))
    assert 'installed callback accepted (HTTP 200)' in logs(fresh), 'helper did not report the callback'
    check_not_logged(fresh, secret_values)
    check_not_stored(fresh, secret_values)
    print('PASS fresh: API and web login, wrong password refused, registration disabled, app.ini values, '
          'UID 1000, SSH answers, repository created and cloned, one callback with token, nothing secret '
          'logged or stored', flush=True)

    # --- restart -------------------------------------------------------------------
    command(['docker', 'restart', '--time', '30', fresh])
    wait_login(fresh, user, password)
    check_logins(fresh, user, password, upgrade_password)
    check_repo(fresh, 'gate-fresh', user, password)
    check_runtime(fresh)
    wait_callbacks(mock, 1, limit=5)
    check_not_logged(fresh, secret_values)
    print('PASS restart: logins work, wrong password refused, repository kept, no second callback', flush=True)
    command(['docker', 'stop', '--time', '30', fresh])

    # --- upgrades from the released images ---------------------------------------
    seen = upgrade('current', mock, 1)
    upgrade('legacy', mock, seen)
except Exception as error:
    print('FAIL release gate: ' + type(error).__name__ + ': ' + redact(str(error)), flush=True)
    raise
finally:
    for name in reversed(containers):
        try:
            found = out(['docker', 'inspect', '--format', '{{index .Config.Labels "appbox.release-gate"}}', name]).strip()
            if found != run_id:
                raise RuntimeError('Container cleanup identity mismatch')
            command(['docker', 'rm', '-f', name])
        except Exception as error:
            print('Cleanup requires attention:', name, type(error).__name__, flush=True)
    for name in volumes:
        try:
            found = out(['docker', 'volume', 'inspect', '--format', '{{index .Labels "appbox.release-gate"}}', name]).strip()
            if found != run_id:
                raise RuntimeError('Volume cleanup identity mismatch')
            command(['docker', 'volume', 'rm', name])
        except Exception as error:
            print('Cleanup requires attention:', name, type(error).__name__, flush=True)
    for name in networks:
        try:
            found = out(['docker', 'network', 'inspect', '--format', '{{index .Labels "appbox.release-gate"}}', name]).strip()
            if found != run_id:
                raise RuntimeError('Network cleanup identity mismatch')
            command(['docker', 'network', 'rm', name])
        except Exception as error:
            print('Cleanup requires attention:', name, type(error).__name__, flush=True)
    if work.parent == Path(tempfile.gettempdir()) and work.name.startswith(run_id + '-'):
        shutil.rmtree(work)

registry.require_absent(image)
print('PASS required release gates', flush=True)
