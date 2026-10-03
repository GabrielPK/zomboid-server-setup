# Zomboid server setup for EC2

Install a fresh Project Zomboid dedicated server on Ubuntu with two prompts: its display name and join password. The installer creates a separate random admin password, runs the game as an unprivileged `zomboid` user, and enables a systemd service that saves and quits during shutdown and starts again on boot.

## Requirements

- Fresh Ubuntu 22.04, 24.04, or 26.04 **x86_64** instance, with sudo access.
- **16 GiB RAM recommended**; the script requires 12 GiB usable memory and assigns an 8 GiB Java heap. It does not create swap.
- At least 15 GiB free disk space; 50 GiB gp3 is a reasonable starting volume.
- Outbound internet access for Ubuntu packages and Steam.
- EC2 security group allowing **UDP 16261–16262** from your players and **TCP 22** from your own IP. An enabled OS firewall also needs the game ports allowed. The installer does not alter firewalls or AWS settings.

## Run

Download `setup-zomboid.sh` from this repository, then run:

```bash
sudo bash setup-zomboid.sh
```

On your fresh Ubuntu instance, download and run:

```bash
curl -fL --proto '=https' 'https://raw.githubusercontent.com/GabrielPK/zomboid-server-setup/main/setup-zomboid.sh' -o setup-zomboid.sh && sudo bash setup-zomboid.sh
```

It asks for:

1. Display name (defaults to `My PZ Server`). The internal save/config name remains `servertest`.
2. Server join password (hidden while typed).

The default Steam branch is `public`, matching the source server when this script was written. Players must use the matching game version. For another branch:

```bash
sudo bash setup-zomboid.sh --branch unstable
```

Expect several minutes for installation and world initialization. Success is reported only after the server logs `SERVER STARTED`. Join using the instance's public/Elastic IP, port **16261**, and your chosen join password. Players use their own character/account login, separate from the shared join password.

Defaults: eight players, pause when empty, not listed publicly, no mods, UPnP disabled, RCON disabled by leaving its password empty. Other gameplay settings use the installed game's defaults.

## Administration

Admin username: `admin`. Retrieve its generated initial password:

```bash
sudo cat /var/lib/zomboid/admin-password.txt
```

This differs from the join password. The launcher supplies it only while initializing a missing admin account; it does not reset an existing account. The initial password is briefly a process argument during first startup, so use a dedicated instance with trusted local users. Both password files are restricted to the service user/root. Do not commit live configs or credentials to GitHub.

```bash
sudo systemctl status zomboid
sudo journalctl -u zomboid -f
sudo systemctl restart zomboid
sudo systemctl stop zomboid
sudo systemctl start zomboid
```

To edit settings:

```bash
sudo systemctl stop zomboid
sudo nano /var/lib/zomboid/Zomboid/Server/servertest.ini
sudo systemctl start zomboid
```

- Installation: `/opt/zomboid/server`
- SteamCMD: `/opt/zomboid/steamcmd`
- Configuration/worlds/logs: `/var/lib/zomboid/Zomboid`
- Service: `/etc/systemd/system/zomboid.service`
- Boot and crash recovery are enabled; three rapid failures trigger systemd's restart limit. After fixing the cause, use `sudo systemctl reset-failed zomboid` and start the service.
- Shutdown sends `quit` and waits up to 180 seconds for saving before systemd's timeout applies.
- An Elastic IP keeps the connection address stable across EC2 stop/start cycles.

Back up `/var/lib/zomboid/Zomboid` while the service is stopped before updates or migration. Protect backups because the configuration contains the join password. This installer does not update the game automatically, migrate an old world, or provide scheduled backups.

## Fresh-install protection and failures

The installer refuses to overwrite known installation paths or an existing `zomboid` account. It is deliberately not an updater. If installation fails partway through, inspect the error and existing files before retrying; it does not delete partially installed files or your data. A Steam or package-download failure may require manual recovery or a new clean instance.

The service may still be loading if the ten-minute readiness timeout expires. Inspect its journal rather than rerunning the installer.

## Validation

```bash
bash -n setup-zomboid.sh
python3 -m unittest discover -s tests -v
```

Tests exercise the actual embedded launcher and shutdown helper with a fake game process, including admin initialization, keeping an existing admin, and graceful shutdown. They do not replace an end-to-end install on a fresh EC2 instance. The systemd/FIFO shutdown approach was separately verified with a real Zomboid server reboot; this complete fresh-instance installer has not yet been run end to end.

Sources: [Valve SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD), [Project Zomboid Steam support](https://steamcommunity.com/app/108600/discussions/1/846243771540628848/).
