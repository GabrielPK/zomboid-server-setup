#!/usr/bin/env bash
# Fresh Ubuntu x86_64 EC2 instance installer. Run: sudo bash setup-zomboid.sh
# Optional: sudo bash setup-zomboid.sh --branch unstable
set -Eeuo pipefail
umask 077
trap 'printf "\nSetup failed at line %s. Inspect: sudo journalctl -u zomboid -n 80\n" "$LINENO" >&2' ERR
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
branch=public
while (($#)); do
  case "$1" in
    --branch) (($# >= 2)) || fail '--branch requires a name'; branch=$2; shift 2 ;;
    -h|--help) printf '%s\n' 'Usage: sudo bash setup-zomboid.sh [--branch public|unstable|BRANCH]' 'Requires a fresh Ubuntu 22.04/24.04/26.04 x86_64 instance, systemd, 16 GiB RAM recommended, and 15 GiB free disk.' 'Prompts for display name and join password. Generates a separate admin password.'; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ $branch =~ ^[a-zA-Z0-9_.-]+$ ]] || fail 'Invalid branch name'
(( EUID == 0 )) || fail 'Run using sudo bash setup-zomboid.sh'
[[ $(uname -m) == x86_64 ]] || fail 'Use an Intel/AMD x86_64 instance; ARM/Graviton is not supported by this installer.'
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID =~ ^(22\.04|24\.04|26\.04)$ ]] || fail 'Supported OS: Ubuntu 22.04, 24.04, or 26.04.'
[[ -d /run/systemd/system ]] || fail 'This installer requires systemd.'
# This is intentionally a fresh-install tool, not an updater or migration tool.
for path in /opt/zomboid /var/lib/zomboid /etc/systemd/system/zomboid.service /usr/local/libexec/zomboid-start /usr/local/libexec/zomboid-stop /home/*/pzserver /home/*/Zomboid /root/Zomboid; do
  [[ ! -e $path ]] || fail "Existing installation or partial setup at $path. Refusing to overwrite it."
done
! id zomboid >/dev/null 2>&1 || fail 'The zomboid user already exists; inspect the previous setup first.'
ram_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
((ram_kib >= 12 * 1024 * 1024)) || fail 'At least 12 GiB usable RAM is required for the 8 GiB Java heap. Choose a 16 GiB instance.'
for path in /opt /var/lib; do
  free_kib=$(df -Pk "$path" | awk 'NR==2 {print $4}')
  ((free_kib >= 15 * 1024 * 1024)) || fail "Need at least 15 GiB free on the filesystem containing $path."
done
exec 9<>/dev/tty || fail 'Run this from an interactive SSH terminal.'
printf 'Zomboid server name [My PZ Server]: ' >&9
IFS= read -r server_name <&9
server_name=${server_name:-My PZ Server}
[[ ${#server_name} -le 100 && ! $server_name =~ [[:cntrl:]] ]] || fail 'Use a server name under 101 characters without control characters.'
while :; do
  printf 'Server join password (hidden; required): ' >&9
  IFS= read -rs join_password <&9
  printf '\n' >&9
  if [[ -n $join_password && ${#join_password} -le 128 && ! $join_password =~ [[:cntrl:]] && $join_password != ' '* && $join_password != *' ' ]]; then break; fi
  printf 'Use 1–128 characters, with no control characters or leading/trailing spaces.\n' >&9
done
exec 9>&-
printf '\nInstalling SteamCMD and Zomboid (%s branch). This can take several minutes.\n' "$branch"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl tar python3 lib32gcc-s1 lib32stdc++6 libatomic1
useradd --system --create-home --home-dir /var/lib/zomboid --shell /usr/sbin/nologin zomboid
install -d -o zomboid -g zomboid -m 750 /opt/zomboid /opt/zomboid/steamcmd /opt/zomboid/server /var/lib/zomboid/Zomboid/Server /var/lib/zomboid/Zomboid/mods
archive=$(mktemp)
curl --fail --show-error --location --retry 3 --proto '=https' https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz -o "$archive"
tar -xzf "$archive" --no-same-owner -C /opt/zomboid/steamcmd
rm -f "$archive"
chown -R zomboid:zomboid /opt/zomboid/steamcmd
runuser -u zomboid -- env HOME=/var/lib/zomboid /opt/zomboid/steamcmd/steamcmd.sh +force_install_dir /opt/zomboid/server +login anonymous +app_update 380870 -beta "$branch" validate +quit
[[ -x /opt/zomboid/server/ProjectZomboid64 && -f /opt/zomboid/server/ProjectZomboid64.json ]] || fail 'SteamCMD did not install the expected server files.'
install -d -o zomboid -g zomboid -m 700 /var/lib/zomboid/.steam/sdk64
ln -s /opt/zomboid/steamcmd/linux64/steamclient.so /var/lib/zomboid/.steam/sdk64/steamclient.so
chown -h zomboid:zomboid /var/lib/zomboid/.steam/sdk64/steamclient.so
printf '%s\n%s\n' "$server_name" "$join_password" | python3 -c '
import json, os, pathlib, secrets
name, password = __import__("sys").stdin.read().split("
")[:2]
p = pathlib.Path("/opt/zomboid/server/ProjectZomboid64.json")
data = json.loads(p.read_text())
data["vmArgs"] = [a for a in data["vmArgs"] if not a.startswith(("-Xmx", "-Xms"))] + ["-Xmx8g"]
p.write_text(json.dumps(data, indent=2) + "\n")
config = pathlib.Path("/var/lib/zomboid/Zomboid/Server/servertest.ini")
config.write_text("\n".join([
    "PublicName=" + name, "Password=" + password,
    "Public=false", "Open=true", "MaxPlayers=8", "PauseEmpty=true",
    "DefaultPort=16261", "UDPPort=16262", "UPnP=false",
    "RCONPassword=", "Mods=", "WorkshopItems=", "",
]))
pathlib.Path("/var/lib/zomboid/admin-password.txt").write_text(secrets.token_hex(16) + "\n")
'
unset join_password
chown -R zomboid:zomboid /var/lib/zomboid/Zomboid /var/lib/zomboid/admin-password.txt
chmod 600 /var/lib/zomboid/admin-password.txt /var/lib/zomboid/Zomboid/Server/servertest.ini
install -d -m 755 /usr/local/libexec
cat > /usr/local/libexec/zomboid-start <<'PY_START'
#!/usr/bin/python3
"""Launch the bundled runtime and initialize the admin only if it does not exist."""
import os
import pathlib
import sqlite3
root = pathlib.Path('/opt/zomboid/server')
home = pathlib.Path('/var/lib/zomboid')
os.chdir(root)
env = dict(os.environ, HOME=str(home))
env['PATH'] = str(root / 'jre64/bin') + ':' + env.get('PATH', '/usr/bin:/bin')
env['LD_LIBRARY_PATH'] = ':'.join(str(p) for p in (root / 'linux64', root, root / 'jre64/lib/amd64'))
env['LD_PRELOAD'] = 'libjsig.so'
args = [str(root / 'ProjectZomboid64'), '-servername', 'servertest']
db = home / 'Zomboid/db/servertest.db'
admin_exists = False
if db.exists():
    with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True) as conn:
        table = conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='whitelist'").fetchone()
        if table:
            admin_exists = bool(conn.execute('SELECT 1 FROM whitelist WHERE username=?', ('admin',)).fetchone())
if not admin_exists:
    args += ['-adminpassword', (home / 'admin-password.txt').read_text().strip()]
fd = os.open('/run/zomboid/console', os.O_RDWR)
os.dup2(fd, 0)
if fd != 0:
    os.close(fd)
os.execve(args[0], args, env)
PY_START
cat > /usr/local/libexec/zomboid-stop <<'PY_STOP'
#!/usr/bin/python3
"""Ask Zomboid to save and quit; wait before systemd terminates remaining processes."""
import os
import sys
import time
pid = int(sys.argv[1])
try:
    fd = os.open('/run/zomboid/console', os.O_WRONLY | os.O_NONBLOCK)
    os.write(fd, b'quit\n')
    os.close(fd)
except OSError as exc:
    print(f'Could not send quit: {exc}', file=sys.stderr)
    sys.exit(1)
while True:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        break
    time.sleep(1)
PY_STOP
chmod 755 /usr/local/libexec/zomboid-start /usr/local/libexec/zomboid-stop
cat > /etc/systemd/system/zomboid.service <<'UNIT'
[Unit]
Description=Project Zomboid Dedicated Server
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
Type=simple
User=zomboid
Group=zomboid
WorkingDirectory=/opt/zomboid/server
Environment=HOME=/var/lib/zomboid
RuntimeDirectory=zomboid
RuntimeDirectoryMode=0700
ExecStartPre=/usr/bin/rm -f /run/zomboid/console
ExecStartPre=/usr/bin/mkfifo -m 600 /run/zomboid/console
ExecStart=/usr/local/libexec/zomboid-start
ExecStop=/usr/local/libexec/zomboid-stop ${MAINPID}
Restart=on-failure
RestartSec=15
TimeoutStopSec=180
KillMode=control-group
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
systemd-analyze verify /etc/systemd/system/zomboid.service
systemctl daemon-reload
systemctl enable --now zomboid
printf '\nWaiting up to 10 minutes for the server to finish loading...\n'
ready=false
for ((i=0; i<120; i++)); do
  if grep -q '\*\*\* SERVER STARTED' /var/lib/zomboid/Zomboid/server-console.txt 2>/dev/null && systemctl is-active --quiet zomboid; then ready=true; break; fi
  if systemctl is-failed --quiet zomboid; then break; fi
  sleep 5
done
[[ $ready == true ]] || fail 'Server did not become ready. Service is installed; inspect its journal before retrying. Do not rerun the installer.'
printf '\nServer "%s" is ready.\n' "$server_name"
printf '%s\n' \
  'Connect using this instance’s public/Elastic IP and port 16261.' \
  'EC2 security group: allow UDP 16261–16262 from your players; SSH TCP 22 from your own IP.' \
  'If an OS firewall is enabled, allow the same game ports there.' \
  'Admin username: admin' \
  'Read the generated admin password: sudo cat /var/lib/zomboid/admin-password.txt' \
  'Config: /var/lib/zomboid/Zomboid/Server/servertest.ini' \
  'Status: sudo systemctl status zomboid' \
  'Logs: sudo journalctl -u zomboid -f' \
  'Restart: sudo systemctl restart zomboid' \
  'Stop: sudo systemctl stop zomboid' \
  'Starts on boot and restarts on failure. No swap, disk, or AWS firewall changes were made.'
