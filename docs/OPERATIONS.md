# Maintenance, Update, Backup & Restore Guide

The installer sets up the unified `cliproxy-manager` CLI.

## Health & Diagnostics

Run system health and listener verification:

```bash
sudo cliproxy-manager check
```

Generate a redacted diagnostics report:

```bash
sudo cliproxy-manager diagnostics
```

## Updates

Check for updates:

```bash
sudo cliproxy-manager check-update
```

Perform an update:

```bash
sudo cliproxy-manager update
```
The updater automatically creates a snapshot before applying changes and rolls back if health checks fail.

## Backups

Create a complete backup (including OAuth data and configurations):

```bash
sudo cliproxy-manager backup
```

Backups are securely saved under `/var/backups/cliproxyapi-account-manager/` with `0700` directory and `0600` file permissions.

## Restore

Restore from the most recent backup:

```bash
sudo cliproxy-manager restore
```

Or restore a specific backup package:

```bash
sudo cliproxy-manager restore /var/backups/cliproxyapi-account-manager/backup_20261111T120000
```

## Uninstall

Safely remove the application while preserving configuration and OAuth credentials:

```bash
sudo cliproxy-manager uninstall
```

To purge all data (destructive):

```bash
sudo cliproxy-manager uninstall --purge-data
```
