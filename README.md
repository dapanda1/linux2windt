# linux2windt

Perl-based file transfer script for Raspberry Pi. Scans a local folder for new files, wakes a Windows server via Wake-on-LAN, transfers files over SMB using `smbclient`, verifies file sizes, and optionally sends a completion report to Home Assistant.

## Files

| File | Purpose |
|---|---|
| `linux2windt.pl` | Main transfer script |
| `linux2windt.conf.example` | Example configuration template — copy to `linux2windt.conf` and fill in your values |
| `migrate.pl` | Config migration engine — auto-applies renames/adds/drops when config schema changes between versions |
| `install.sh` | Copies example config, sets up cron job, desktop icon, permissions, checks dependencies |
| `uninstall.sh` | Removes cron job and desktop shortcut (preserves logs) |
| `.gitignore` | Keeps `linux2windt.conf` (credentials), `.schema_version`, and logs out of the repo |

## Quick Start

```bash
# 1. Clone to your Pi
git clone https://github.com/dapanda1/service-manager.git
cd service-manager

# 2. Run the installer (creates linux2windt.conf from the example template)
bash install.sh

# 3. Edit the config with your actual values
nano linux2windt.conf

# 4. Test with a dry run
perl linux2windt.pl --dry-run

# 5. Run for real
perl linux2windt.pl
```

## How It Runs

- **Scheduled**: Cron runs it daily at the time set in `CRON_SCHEDULE` (default 2:00 AM).
- **Manual**: Double-click the "linux2windt" icon on the Raspberry Pi desktop, or run `perl linux2windt.pl` from the terminal.

## What It Does Each Run

1. Scans `SOURCE_DIR` for files not yet in the processed log.
2. Sends Wake-on-LAN packets to the Windows server.
3. Waits for the server to respond to pings.
4. Transfers each new file via `smbclient`, preserving subdirectory structure.
5. Verifies the remote file size matches the local file size.
6. Marks successfully transferred files so they're skipped next time.
7. Optionally sends a summary report to Home Assistant (mobile push + persistent notification).

## Logs

All logs go to the `LOG_DIR` path set in config.

- `transfer.log` — Full activity log (info + errors)
- `errors.log` — Errors only, for quick troubleshooting
- `processed.log` — List of files already transferred (one relative path per line)

Logs auto-rotate at `LOG_MAX_SIZE` (default 5 MB), keeping `LOG_KEEP_COUNT` backups.

## Config Reference

See `linux2windt.conf.example` — every setting is commented inline. Copy it to `linux2windt.conf` and fill in these required values:

- `SOURCE_DIR` — Local folder to scan for new files
- `SMB_SERVER_IP` — IP address of the Windows SMB server
- `SMB_SHARE` — Name of the SMB share
- `SMB_USER` / `SMB_PASS` — Windows share credentials
- `WOL_MAC` — MAC address of the server to wake
- `LOG_DIR` — Where to write logs

Optional — Home Assistant notifications (disabled by default):

- `HA_NOTIFY_ENABLED` — Set to `1` to enable
- `HA_URL` — Home Assistant base URL (e.g. `http://homeassistant.local:8123`)
- `HA_TOKEN` — Home Assistant long-lived access token
- `HA_NOTIFY_SERVICE` — HA notify service name (e.g. `notify.mobile_app_your_phone`)

**Important:** `linux2windt.conf` is gitignored. Never commit your real credentials.

## Dependencies

Installed automatically by `install.sh` if missing:

- `perl`
- `smbclient`
- `curl`
- `libjson-pp-perl` (Perl JSON::PP module)
- `iputils-ping`

## Updating

```bash
# 1. Clone the latest version
git clone https://github.com/dapanda1/service-manager.git service-manager-new
cd service-manager-new

# 2. Copy your existing config into the new clone
cp /path/to/old/service-manager/linux2windt.conf .

# 3. Re-run the installer
bash install.sh

# 4. The first run automatically migrates your config
perl linux2windt.pl --dry-run
```

When the script starts, `migrate.pl` checks your config's schema version against the current version. If the schema has changed (new keys, renamed keys, dropped keys), it applies the changes automatically — your existing values are preserved. A `.bak` backup of the config is created before any changes are written.

To preview what a migration would do without applying it:

```bash
perl migrate.pl --dry-run
```
