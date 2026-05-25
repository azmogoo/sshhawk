# SSHawk Project Report (AP3 Linux)

## Introduction

In this project, we built **SSHawk**, a minimalist SSH log analyzer written mainly in Bash. The goal is to detect failed SSH authentication attempts from Linux logs, aggregate them by source IP address and username, and generate a clean security report. Optionally, the tool can geolocate source IPs using a public API.

## Why we chose this subject

SSH is a common entry point to Linux systems. Attackers often try many username/password combinations or probe for open SSH services. Even when a system is not compromised, failed login attempts can be a strong signal of scanning or brute-force attacks.

This subject combines several course topics: reading system logs, using text-processing tools, writing Bash scripts with functions and parameters, and integrating a simple network call with `curl`.

## Linux concepts used

- Shell scripting with functions and command-line arguments
- Reading system logs:
  - `/var/log/auth.log`
  - `journalctl` for service logs (`ssh` / `sshd`)
- Using classic text tools: `grep`, `awk`, `sed`, `sort`, `uniq`, `head`, `wc`
- Handling program flow with conditions and loops
- File and permission checks (to fail safely when logs are unreadable)

## How SSH logs work

OpenSSH records authentication-related events in logs. Typical patterns include:

- `Failed password for ... from <IP> ...`
- `Failed publickey for ... from <IP> ...`
- `Invalid user ... from <IP>`
- `authentication failure ... rhost=<IP> user=<username>`

These lines contain the source IP address and sometimes the attempted username. By filtering only failure-related patterns, we can estimate which IPs are most active.

## How the script extracts data

SSHawk follows these steps:

1. **Collect logs** from a chosen source:
   - authlog: reads `/var/log/auth.log`
   - journalctl: runs `journalctl -u ssh` or `journalctl -u sshd`
   - file: reads the provided test file
2. **Extract failed events** by searching for known failure messages.
3. **Parse each failed line** to extract:
   - source IP address (IPv4)
   - attempted username (when present in the line)
   - timestamp (best-effort syslog parsing)
4. **Aggregate**:
   - counts failed attempts per IP
   - tracks first and last timestamps per IP
   - counts usernames to show the top targets

## How geolocation works with `curl`

When geolocation is enabled (default), SSHawk geolocates each top attacking IP using:

`http://ip-api.com/json/<IP>?fields=status,country,regionName,city,isp,query`

Key details:

- Geolocation is cached in-memory during one execution (so the same IP is not queried twice).
- A short delay is added between API calls to reduce the chance of rate limiting.
- If the API fails or returns an error status, the tool uses `Unknown` instead of crashing.

## Screenshots / placeholders

Placeholders for demonstration:

- Screenshot 1: running SSHawk on the sample log
- Screenshot 2: generated Markdown report output
- Screenshot 3: running SSHawk on real logs (with sudo)

## Problems encountered

- `journalctl` unit names differ between systems (`ssh` vs `sshd`), so we added a unit detection step.
- Different failure formats require heuristic parsing of usernames (for example `user=...` inside `authentication failure` lines).
- Geolocation can fail due to network restrictions, so graceful fallback to `Unknown` is necessary.

## Possible improvements

- Add support for more log patterns and improve false-positive filtering.
- Add IPv6 parsing and reporting.
- Stream logs to reduce memory usage on large servers.
- Provide more structured output (e.g., JSON) for integration with other security tools.
- Add an optional scheduled run using `cron` or a `systemd` timer.

## Conclusion

SSHawk is a functional and educational tool that demonstrates core Linux command-line skills. It can quickly turn SSH failure logs into a report useful for monitoring and early warning, while remaining safe by design (read-only log analysis, no configuration changes).

