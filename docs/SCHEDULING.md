# Scheduling SSHawk (optional)

SSHawk can be run periodically with **cron** or a **systemd timer**.  
Both methods only generate reports (read-only).

Adjust paths below if the project is not in `/home/ubuntu/sshhawk`.

## Cron example

Edit crontab:

```bash
crontab -e
```

Daily report at 06:30 (no geolocation to avoid rate limits):

```cron
30 6 * * * /home/ubuntu/sshhawk/scripts/run_scheduled_report.sh >> /home/ubuntu/sshhawk/reports/cron.log 2>&1
```

## Systemd timer example

Copy unit files (or symlink):

```bash
sudo cp systemd/sshawk-report.service /etc/systemd/system/
sudo cp systemd/sshawk-report.timer /etc/systemd/system/
```

Edit `WorkingDirectory` and `ExecStart` in the service file if needed, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now sshawk-report.timer
sudo systemctl list-timers | grep sshawk
```

Run once manually:

```bash
sudo systemctl start sshawk-report.service
```

Reports are written under `reports/` with the usual timestamped filename.

## Notes

- Reading `/var/log/auth.log` usually requires root (service runs as root or with sudo).
- Use `--no-geo` for automated runs unless you accept API rate limits.
- Generated reports may contain sensitive data; protect the `reports/` directory.
