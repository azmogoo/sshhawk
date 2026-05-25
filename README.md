# SSHawk — A minimalist SSH log analyzer and reporting tool

SSHawk is a simple Bash project for AP3 Introduction to Linux. It reads SSH authentication logs (for example `/var/log/auth.log` or `journalctl -u ssh/sshd`), detects failed login attempts, aggregates them by source IP and username, optionally geolocates source IPs using `curl`, and generates a readable security report.

This project is intentionally minimalist: it demonstrates practical Linux command-line skills with a Bash-first implementation, classic text processing tools, and clean report output.

## Features

- Analyze SSH logs from:
  - `/var/log/auth.log` (`--source authlog`)
  - `journalctl` unit logs (`--source journalctl`, detects `ssh` or `sshd`)
  - a custom file for testing (`--file samples/sample-auth.log`)
- Detect common failed SSH authentication patterns:
  - "Failed password for ..."
  - "Failed publickey for ..."
  - "Invalid user ..."
  - "authentication failure"
- Extract for each failed attempt:
  - source IP address
  - attempted username when available
  - first and last timestamps per IP (best effort)
- Aggregate:
  - number of failed attempts per IP
  - top targeted usernames
  - total failed attempts
  - total unique attacking IPs
- Optional geolocation:
  - enabled by default (unless `--no-geo`)
  - uses a free public API (`ip-api.com`) via `curl`
  - includes caching during one execution to avoid repeated calls
- Report generation:
  - default output: `reports/ssh_report_YYYY-MM-DD_HH-MM-SS.md`
  - output formats: Markdown (`--format markdown`) or text (`--format text`)

## Prerequisites

On Ubuntu, you should have:

- `bash`
- `grep`, `awk`, `sed`, `sort`, `uniq`, `head`, `tail`, `wc`
- `curl`
- `journalctl` and `systemctl` (for `--source journalctl`)
- `git`

If some commands are missing, install with your course instructions (for example `sudo apt install curl`).

## Installation

```bash
cd /path/to/work
git clone <your-repo-url> sshhawk
cd sshhawk
chmod +x sshawk.sh
chmod +x tests/test_sample_log.sh
```

## Usage

### Help

```bash
./sshawk.sh --help
```

### Run on the sample file (recommended for testing)

```bash
./sshawk.sh --file samples/sample-auth.log --no-geo
```

### Run on real logs

```bash
sudo ./sshawk.sh --source authlog --top 10
```

### Run using journalctl

```bash
sudo ./sshawk.sh --source journalctl --since "2026-05-01"
```

### Custom output path / format

```bash
./sshawk.sh --file samples/sample-auth.log --no-geo --format text --output /tmp/sshhawk_report.txt
```

## Privacy warning (important)

Real SSH logs can contain sensitive information (usernames, IP addresses, and other metadata).
SSHawk only **reads logs** and **generates a report**. Do not upload reports or raw logs to public places if they may reveal personal or confidential data.
For the repository, only a fake sample log is included.

## How reports are generated

- Default output directory is `reports/`
- Default report naming format:
  - `reports/ssh_report_YYYY-MM-DD_HH-MM-SS.md`
- Reports include:
  - project name and execution date
  - hostname
  - analyzed source
  - total failed attempts and unique attacking IPs
  - top attacking IPs with (optional) geolocation
  - top targeted usernames
  - short security observations and recommendations

## Project structure

```text
sshhawk/
├── README.md
├── LICENSE
├── .gitignore
├── sshawk.sh
├── config/
│   └── sshawk.conf
├── samples/
│   └── sample-auth.log
├── reports/
│   └── .gitkeep
├── docs/
│   ├── PROJECT_REPORT.md
│   └── DEMO.md
└── tests/
    └── test_sample_log.sh
```

## authors

- student 1: firstname lastname
- student 2: firstname lastname

## Limitations

- Timestamp extraction is best-effort and depends on log format.
- Username parsing is heuristic: usernames may appear in slightly different patterns depending on the failure type.
- Geolocation uses a public API and may fail or return `Unknown` if the network is unavailable or the API rate limits requests.
- This project is meant for analysis and reporting only; it does not block attackers.

## Possible improvements

- Add more failure patterns (with careful testing to avoid false positives).
- Support IPv6 addresses (more parsing work).
- Stream logs without storing large temporary files.
- Add an optional HTML report template.
- Integrate with `cron` or a `systemd` timer for periodic reporting (if allowed by the course).

