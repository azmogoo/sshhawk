# SSHawk Demo Guide (AP3 Linux)

This document describes a simple demo scenario to show how SSHawk works on a sample log, then on real SSH logs.

## 1) Clone the repository

```bash
cd /home/ubuntu
git clone <your-repo-url> sshhawk
cd sshhawk
```

## 2) Make the main script executable

```bash
chmod +x sshawk.sh
chmod +x tests/test_sample_log.sh
```

## 3) Run on the sample log

```bash
./sshawk.sh --file samples/sample-auth.log --no-geo
```

This generates a Markdown report in `reports/`.

To force a deterministic output path:

```bash
./sshawk.sh --file samples/sample-auth.log --no-geo --output /tmp/sshhawk_demo_report.md
```

## 4) Run on real logs (auth.log)

Depending on server permissions:

```bash
sudo ./sshawk.sh --source authlog
```

## 5) Run using journalctl

```bash
sudo ./sshawk.sh --source journalctl
```

Optional filter since a given date:

```bash
sudo ./sshawk.sh --source journalctl --since "2026-05-01"
```

## 6) Show the generated report

Examples:

```bash
ls -la reports/
less reports/ssh_report_*.md
```

You should see:
- total failed attempts
- unique attacking IPs
- top attacking IPs (with geolocation if enabled)
- top targeted usernames

