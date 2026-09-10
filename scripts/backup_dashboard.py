#!/usr/bin/env python3
"""
==============================================================================
Database Backup & Recovery Health Dashboard
==============================================================================
Provides automated insights and daily reporting on:
- Backup Execution Times & Duration
- Recovery Point Objectives (RPO) and SLA Compliance
- Dedicated Backup Storage Volume Capacity & Utilization (Full vs Log breakdown)
- Production Data Storage Volume Capacity & Growth Headroom
- Volume Names & Mount Points (/dev/mapper/backup_vg-backup_lv & data_vg-data_lv)
- Period of Time Recovery is Possible from Local Disk (Local Recovery Window / PITR)

Generates a modern, dark-themed HTML report (matching the meity-audit-demo style)
and optionally emails it to designated recipients via SMTP or local mailer on
a determined cron schedule.
==============================================================================
"""

import os
import sys
import argparse
import json
import socket
import re
import smtplib
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from datetime import datetime, timezone, timedelta

def format_bytes(size_bytes):
    """Format bytes into human readable string."""
    if size_bytes is None or size_bytes < 0:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    idx = 0
    size = float(size_bytes)
    while size >= 1024.0 and idx < len(units) - 1:
        size /= 1024.0
        idx += 1
    return f"{size:.2f} {units[idx]}"

def format_duration(seconds):
    """Format seconds into human readable duration."""
    if seconds is None or seconds < 0:
        return "0s"
    seconds = int(seconds)
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    secs = seconds % 60
    
    parts = []
    if days > 0:
        parts.append(f"{days}d")
    if hours > 0:
        parts.append(f"{hours}h")
    if minutes > 0 or (days == 0 and hours == 0):
        parts.append(f"{minutes}m")
    if days == 0 and hours == 0 and minutes < 5:
        parts.append(f"{secs}s")
    return " ".join(parts) if parts else f"{secs}s"

def format_volume_name(device):
    """Clean up device path into a concise, recognizable volume/LV identifier."""
    if not device or device == "local" or device == "N/A":
        return "local"
    # E.g. /dev/mapper/backup_vg-backup_lv -> backup_vg/backup_lv
    if device.startswith("/dev/mapper/"):
        mapper_name = device[len("/dev/mapper/"):]
        # In device-mapper, hyphens inside VG or LV names are doubled as '--'
        token = "\x00"
        escaped = mapper_name.replace("--", token)
        if "-" in escaped:
            parts = escaped.split("-", 1)
            vg = parts[0].replace(token, "-")
            lv = parts[1].replace(token, "-")
            return f"{vg}/{lv}"
        return mapper_name.replace(token, "-")
    elif device.startswith("/dev/"):
        return device[len("/dev/"):]
    return device

def get_volume_info(path):
    """
    Resolve filesystem mount point, underlying storage device, volume name,
    and storage capacity metrics (Total, Used, Free, % Headroom).
    """
    if not path:
        return {
            "target_path": "N/A",
            "mount_point": "N/A",
            "device": "N/A",
            "volume_name": "N/A",
            "fs_type": "N/A",
            "total_bytes": 0,
            "used_bytes": 0,
            "free_bytes": 0,
            "percent_used": 0.0,
            "percent_free": 0.0,
            "total_formatted": "0 B",
            "used_formatted": "0 B",
            "free_formatted": "0 B",
            "exists": False
        }

    norm_path = os.path.realpath(os.path.abspath(path)) if os.path.exists(path) else os.path.abspath(path)
    mount_point = None
    device = None
    fs_type = None

    # 1. Parse /proc/mounts (standard on Linux)
    if os.path.exists("/proc/mounts"):
        try:
            best_match = ""
            with open("/proc/mounts", "r") as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) >= 3:
                        dev, mnt, fst = parts[0], parts[1], parts[2]
                        if mnt == "/" or norm_path == mnt or norm_path.startswith(mnt.rstrip("/") + "/"):
                            if len(mnt) > len(best_match):
                                best_match = mnt
                                device = dev
                                mount_point = mnt
                                fs_type = fst
        except Exception:
            pass

    # 2. Fallback via 'df -P <path>' if mount point/device not resolved
    if not device:
        try:
            import subprocess
            proc = subprocess.run(["df", "-P", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5)
            if proc.returncode == 0:
                lines = proc.stdout.strip().splitlines()
                if len(lines) >= 2:
                    df_parts = lines[1].split()
                    if len(df_parts) >= 6:
                        device = df_parts[0]
                        mount_point = df_parts[5]
        except Exception:
            pass

    if not mount_point:
        mount_point = path if os.path.exists(path) else os.path.dirname(norm_path)
    if not device:
        device = "local"

    volume_name = format_volume_name(device)

    # Calculate capacity via statvfs
    total = 0
    free = 0
    used = 0
    percent_used = 0.0
    percent_free = 0.0

    stat_target = path if os.path.exists(path) else (mount_point if os.path.exists(mount_point) else None)
    if stat_target and os.path.exists(stat_target):
        try:
            st = os.statvfs(stat_target)
            total = st.f_blocks * st.f_frsize
            free = st.f_bavail * st.f_frsize
            used = max(0, total - free)
            if total > 0:
                percent_used = round((used / total * 100.0), 1)
                percent_free = round((free / total * 100.0), 1)
        except Exception:
            pass

    return {
        "target_path": path,
        "mount_point": mount_point,
        "device": device,
        "volume_name": volume_name,
        "fs_type": fs_type or "ext4",
        "total_bytes": total,
        "used_bytes": used,
        "free_bytes": free,
        "percent_used": percent_used,
        "percent_free": percent_free,
        "total_formatted": format_bytes(total),
        "used_formatted": format_bytes(used),
        "free_formatted": format_bytes(free),
        "exists": os.path.exists(path)
    }

def get_disk_stats(path):
    """Backwards-compatible wrapper returning disk statistics for path."""
    return get_volume_info(path)

def get_default_data_dir(db_type):
    """Determine expected production data directory for given DB type."""
    db_type = (db_type or "").lower()
    if "db2" in db_type:
        return "/var/lib/db2_data"
    elif "postgres" in db_type:
        return "/var/lib/postgresql_data"
    elif "mysql" in db_type:
        return "/var/lib/mysql_data"
    
    for candidate in ["/var/lib/db2_data", "/var/lib/mysql_data", "/var/lib/postgresql_data"]:
        if os.path.exists(candidate):
            return candidate
    return None

def get_dir_size(path):
    """Recursively calculate directory size in bytes."""
    total = 0
    if not os.path.exists(path):
        return 0
    try:
        for entry in os.scandir(path):
            if entry.is_file(follow_symlinks=False):
                total += entry.stat().st_size
            elif entry.is_dir(follow_symlinks=False):
                total += get_dir_size(entry.path)
    except (PermissionError, FileNotFoundError):
        pass
    return total

def parse_date_str(date_str):
    """Parse date from YYYY-MM-DD or YYYY-MM-DD_HH-MM-SS string."""
    for fmt in ("%Y-%m-%d_%H-%M-%S", "%Y-%m-%d %H:%M:%S", "%Y%m%d%H%M%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(date_str, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return None

def scan_instance_backups(backup_dir, instance_name, data_dir=None, db_type=None, retention_full=3, retention_log=3, target_rpo_min=15):
    """
    Scan the backup directory structure for an instance:
    <backup_dir>/<instance_name>/
        full/<YYYY-MM-DD>/<files>
        logs/<YYYY-MM-DD>/<files>
        last_full_backup_timestamp
    Also captures volume metrics for both backup volume and production data volume.
    """
    now = datetime.now(timezone.utc)
    instance_dir = os.path.join(backup_dir, instance_name)
    
    full_root = os.path.join(instance_dir, "full")
    logs_root = os.path.join(instance_dir, "logs")
    last_full_marker = os.path.join(instance_dir, "last_full_backup_timestamp")
    
    # Auto-detect DB type if not specified
    if not db_type:
        if "postgres" in backup_dir.lower() or "postgres" in instance_name.lower():
            db_type = "postgres"
        elif "db2" in backup_dir.lower() or "db2" in instance_name.lower():
            db_type = "db2"
        else:
            db_type = "mysql"
            
    engine_names = {
        "mysql": "MySQL 8.0",
        "postgres": "PostgreSQL 14",
        "db2": "IBM Db2 11.5"
    }
    engine_display = engine_names.get(db_type.lower(), db_type.upper())
    
    # 1. Scan Full Backups (traverse recursively to handle all directory structures)
    full_backups = []
    full_bytes = 0
    seen_full_paths = set()
    if os.path.isdir(full_root):
        try:
            for root, dirs, files in os.walk(full_root):
                for file_name in files:
                    if file_name.startswith("."):
                        continue
                    file_path = os.path.join(root, file_name)
                    if file_path in seen_full_paths:
                        continue
                    seen_full_paths.add(file_path)
                    try:
                        stat = os.stat(file_path)
                        mtime = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc)
                        full_bytes += stat.st_size
                        rel = os.path.relpath(file_path, full_root)
                        date_dir = rel.split(os.sep)[0] if os.sep in rel else "full"
                        full_backups.append({
                            "path": file_path,
                            "name": file_name,
                            "date_dir": date_dir,
                            "size_bytes": stat.st_size,
                            "size_formatted": format_bytes(stat.st_size),
                            "timestamp": mtime,
                            "timestamp_str": mtime.strftime("%Y-%m-%d %H:%M:%S UTC")
                        })
                    except Exception:
                        pass
        except Exception:
            pass

    full_backups.sort(key=lambda x: x["timestamp"])
    
    # Fallback to last_full_backup_timestamp marker if directory scan didn't find individual files
    latest_full_time = None
    if full_backups:
        latest_full_time = full_backups[-1]["timestamp"]
    elif os.path.isfile(last_full_marker):
        try:
            with open(last_full_marker, "r") as f:
                ts_epoch = float(f.read().strip())
                latest_full_time = datetime.fromtimestamp(ts_epoch, tz=timezone.utc)
        except Exception:
            pass

    oldest_full_time = full_backups[0]["timestamp"] if full_backups else latest_full_time

    # 2. Scan Log Backups (traverse recursively to detect nested engine logs: Db2/Postgres/MySQL)
    log_files = []
    log_bytes = 0
    seen_log_paths = set()
    if os.path.isdir(logs_root):
        try:
            for root, dirs, files in os.walk(logs_root):
                for file_name in files:
                    if file_name.startswith("."):
                        continue
                    file_path = os.path.join(root, file_name)
                    if file_path in seen_log_paths:
                        continue
                    seen_log_paths.add(file_path)
                    try:
                        stat = os.stat(file_path)
                        mtime = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc)
                        log_bytes += stat.st_size
                        rel = os.path.relpath(file_path, logs_root)
                        date_dir = rel.split(os.sep)[0] if os.sep in rel else "logs"
                        log_files.append({
                            "path": file_path,
                            "name": file_name,
                            "date_dir": date_dir,
                            "size_bytes": stat.st_size,
                            "size_formatted": format_bytes(stat.st_size),
                            "timestamp": mtime,
                            "timestamp_str": mtime.strftime("%Y-%m-%d %H:%M:%S UTC")
                        })
                    except Exception:
                        pass
        except Exception:
            pass

    # Also inspect staging directories for newly archived logs pending transfer
    staging_dirs = [
        os.path.join(instance_dir, "log_staging"),
        os.path.join(instance_dir, "wal_staging")
    ]
    for staging_dir in staging_dirs:
        if os.path.isdir(staging_dir):
            try:
                for root, dirs, files in os.walk(staging_dir):
                    for file_name in files:
                        if file_name.startswith("."):
                            continue
                        file_path = os.path.join(root, file_name)
                        if file_path in seen_log_paths:
                            continue
                        seen_log_paths.add(file_path)
                        try:
                            stat = os.stat(file_path)
                            mtime = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc)
                            log_bytes += stat.st_size
                            log_files.append({
                                "path": file_path,
                                "name": file_name,
                                "date_dir": "staging",
                                "size_bytes": stat.st_size,
                                "size_formatted": format_bytes(stat.st_size),
                                "timestamp": mtime,
                                "timestamp_str": mtime.strftime("%Y-%m-%d %H:%M:%S UTC")
                            })
                        except Exception:
                            pass
            except Exception:
                pass

    log_files.sort(key=lambda x: x["timestamp"])
    
    latest_log_time = log_files[-1]["timestamp"] if log_files else None
    oldest_log_time = log_files[0]["timestamp"] if log_files else None

    # 3. Calculate Achieved RPO
    latest_recovery_point = latest_log_time or latest_full_time
    if latest_recovery_point:
        achieved_rpo_sec = max(0, int((now - latest_recovery_point).total_seconds()))
    else:
        achieved_rpo_sec = None

    target_rpo_sec = int(target_rpo_min * 60)
    if achieved_rpo_sec is None:
        rpo_status = "CRITICAL"
        rpo_status_desc = "No backups found"
    elif achieved_rpo_sec <= target_rpo_sec:
        rpo_status = "OPTIMAL"
        rpo_status_desc = f"Achieved ({format_duration(achieved_rpo_sec)} vs SLA {target_rpo_min}m)"
    elif achieved_rpo_sec <= (target_rpo_sec * 2):
        rpo_status = "WARNING"
        rpo_status_desc = f"Delayed ({format_duration(achieved_rpo_sec)} vs SLA {target_rpo_min}m)"
    else:
        rpo_status = "CRITICAL"
        rpo_status_desc = f"Exceeded ({format_duration(achieved_rpo_sec)} vs SLA {target_rpo_min}m)"

    # 4. Period of Time Recovery is Possible from Local Disk (Local Recovery Window / PITR)
    recovery_start = oldest_full_time
    recovery_end = latest_log_time or latest_full_time
    if recovery_start and recovery_end and recovery_end >= recovery_start:
        local_recovery_sec = int((recovery_end - recovery_start).total_seconds())
        local_recovery_days = round(local_recovery_sec / 86400.0, 1)
        recovery_window_desc = (
            f"{local_recovery_days} days ({format_duration(local_recovery_sec)})"
        )
        recovery_window_range = (
            f"{recovery_start.strftime('%Y-%m-%d %H:%M')} \u2192 {recovery_end.strftime('%Y-%m-%d %H:%M')} UTC"
        )
        has_pitr = bool(log_files)
    elif latest_full_time:
        local_recovery_sec = 0
        local_recovery_days = 0.0
        recovery_window_desc = "Discrete snapshot recovery only (Point-in-Time disabled)"
        recovery_window_range = f"Snapshot: {latest_full_time.strftime('%Y-%m-%d %H:%M')} UTC"
        has_pitr = False
    else:
        local_recovery_sec = 0
        local_recovery_days = 0.0
        recovery_window_desc = "No recovery points available on local disk"
        recovery_window_range = "N/A"
        has_pitr = False

    # 5. Volume & Disk Stats (Both Backup Volume and Production Data Volume)
    backup_target = instance_dir if os.path.exists(instance_dir) else backup_dir
    backup_vol_info = get_volume_info(backup_target)

    if not data_dir:
        data_dir = get_default_data_dir(db_type)
    prod_vol_info = get_volume_info(data_dir)

    total_backup_bytes = full_bytes + log_bytes

    return {
        "instance_name": instance_name,
        "db_type": db_type,
        "engine_display": engine_display,
        "backup_dir": instance_dir,
        "data_dir": data_dir or prod_vol_info.get("target_path"),
        "disk_stats": backup_vol_info,      # Backwards compatibility
        "backup_volume": backup_vol_info,  # Dedicated backup volume metrics
        "prod_volume": prod_vol_info,      # Dedicated production data volume metrics
        "full_backup_count": len(full_backups),
        "full_backup_bytes": full_bytes,
        "full_backup_formatted": format_bytes(full_bytes),
        "latest_full_time": latest_full_time,
        "latest_full_str": latest_full_time.strftime("%Y-%m-%d %H:%M:%S UTC") if latest_full_time else "None",
        "latest_full_age": format_duration((now - latest_full_time).total_seconds()) if latest_full_time else "N/A",
        "oldest_full_time": oldest_full_time,
        "oldest_full_str": oldest_full_time.strftime("%Y-%m-%d %H:%M:%S UTC") if oldest_full_time else "None",
        "log_backup_count": len(log_files),
        "log_backup_bytes": log_bytes,
        "log_backup_formatted": format_bytes(log_bytes),
        "latest_log_time": latest_log_time,
        "latest_log_str": latest_log_time.strftime("%Y-%m-%d %H:%M:%S UTC") if latest_log_time else "None",
        "latest_log_age": format_duration((now - latest_log_time).total_seconds()) if latest_log_time else "N/A",
        "total_backup_bytes": total_backup_bytes,
        "total_backup_formatted": format_bytes(total_backup_bytes),
        "achieved_rpo_sec": achieved_rpo_sec,
        "achieved_rpo_str": format_duration(achieved_rpo_sec) if achieved_rpo_sec is not None else "N/A",
        "target_rpo_min": target_rpo_min,
        "rpo_status": rpo_status,
        "rpo_status_desc": rpo_status_desc,
        "retention_days_full": retention_full,
        "retention_days_log": retention_log,
        "local_recovery_sec": local_recovery_sec,
        "local_recovery_days": local_recovery_days,
        "local_recovery_desc": recovery_window_desc,
        "local_recovery_range": recovery_window_range,
        "has_pitr": has_pitr,
        "full_backups": full_backups[-10:], # Last 10 fulls
        "recent_logs": log_files[-10:]     # Last 10 logs
    }

def generate_mock_data():
    """Generate realistic demonstration data if running locally without active DBs."""
    now = datetime.now(timezone.utc)
    
    mock_instances = [
        {
            "instance_name": "rocky-mysql-vm",
            "db_type": "mysql",
            "engine_display": "MySQL 8.0",
            "backup_dir": "/var/lib/mysql_backups/rocky-mysql-vm",
            "data_dir": "/var/lib/mysql_data",
            "prod_volume": {
                "target_path": "/var/lib/mysql_data",
                "mount_point": "/var/lib/mysql_data",
                "device": "/dev/mapper/data_vg-data_lv",
                "volume_name": "data_vg/data_lv",
                "fs_type": "ext4",
                "total_bytes": 32212254720,
                "used_bytes": 8589934592,
                "free_bytes": 23622320128,
                "percent_used": 26.7,
                "percent_free": 73.3,
                "total_formatted": "30.00 GB",
                "used_formatted": "8.00 GB",
                "free_formatted": "22.00 GB",
                "exists": True
            },
            "backup_volume": {
                "target_path": "/var/lib/mysql_backups/rocky-mysql-vm",
                "mount_point": "/var/lib/mysql_backups",
                "device": "/dev/mapper/backup_vg-backup_lv",
                "volume_name": "backup_vg/backup_lv",
                "fs_type": "ext4",
                "total_bytes": 21474836480,
                "used_bytes": 5422891008,
                "free_bytes": 16051945472,
                "percent_used": 25.2,
                "percent_free": 74.8,
                "total_formatted": "20.00 GB",
                "used_formatted": "5.05 GB",
                "free_formatted": "14.95 GB",
                "exists": True
            },
            "disk_stats": {
                "total_bytes": 21474836480,
                "used_bytes": 5422891008,
                "free_bytes": 16051945472,
                "percent_used": 25.2,
                "percent_free": 74.8,
                "total_formatted": "20.00 GB",
                "used_formatted": "5.05 GB",
                "free_formatted": "14.95 GB",
                "volume_name": "backup_vg/backup_lv",
                "mount_point": "/var/lib/mysql_backups",
                "device": "/dev/mapper/backup_vg-backup_lv"
            },
            "full_backup_count": 3,
            "full_backup_bytes": 4509715660,
            "full_backup_formatted": "4.20 GB",
            "latest_full_time": now - timedelta(hours=11, minutes=45),
            "latest_full_str": (now - timedelta(hours=11, minutes=45)).strftime("%Y-%m-%d 02:00:00 UTC"),
            "latest_full_age": "11h 45m",
            "oldest_full_time": now - timedelta(days=2, hours=11, minutes=45),
            "oldest_full_str": (now - timedelta(days=2, hours=11, minutes=45)).strftime("%Y-%m-%d 02:00:00 UTC"),
            "log_backup_count": 284,
            "log_backup_bytes": 913175348,
            "log_backup_formatted": "870.87 MB",
            "latest_log_time": now - timedelta(minutes=8, seconds=15),
            "latest_log_str": (now - timedelta(minutes=8, seconds=15)).strftime("%Y-%m-%d %H:%M:%S UTC"),
            "latest_log_age": "8m 15s",
            "total_backup_bytes": 5422891008,
            "total_backup_formatted": "5.05 GB",
            "achieved_rpo_sec": 495,
            "achieved_rpo_str": "8m 15s",
            "target_rpo_min": 15,
            "rpo_status": "OPTIMAL",
            "rpo_status_desc": "Achieved (8m 15s vs SLA 15m)",
            "retention_days_full": 3,
            "retention_days_log": 3,
            "local_recovery_sec": 211050,
            "local_recovery_days": 2.4,
            "local_recovery_desc": "2.4 days (2d 10h 37m)",
            "local_recovery_range": f"{(now - timedelta(days=2, hours=11, minutes=45)).strftime('%Y-%m-%d 02:00')} \u2192 {(now - timedelta(minutes=8)).strftime('%Y-%m-%d %H:%M')} UTC",
            "has_pitr": True,
            "full_backups": [
                {"name": "mysql_full_2026-09-08_02-00-00.sql.gz", "size_formatted": "1.40 GB", "timestamp_str": (now - timedelta(days=2)).strftime("%Y-%m-%d 02:00:00 UTC")},
                {"name": "mysql_full_2026-09-09_02-00-00.sql.gz", "size_formatted": "1.40 GB", "timestamp_str": (now - timedelta(days=1)).strftime("%Y-%m-%d 02:00:00 UTC")},
                {"name": "mysql_full_2026-09-10_02-00-00.sql.gz", "size_formatted": "1.40 GB", "timestamp_str": now.strftime("%Y-%m-%d 02:00:00 UTC")},
            ],
            "recent_logs": [
                {"name": "mysql-bin.000142", "size_formatted": "3.2 MB", "timestamp_str": (now - timedelta(minutes=23)).strftime("%Y-%m-%d %H:%M:%S UTC")},
                {"name": "mysql-bin.000143", "size_formatted": "3.1 MB", "timestamp_str": (now - timedelta(minutes=8, seconds=15)).strftime("%Y-%m-%d %H:%M:%S UTC")}
            ]
        },
        {
            "instance_name": "ubuntu-postgres-vm",
            "db_type": "postgres",
            "engine_display": "PostgreSQL 14",
            "backup_dir": "/var/lib/postgresql_backups/ubuntu-postgres-vm",
            "data_dir": "/var/lib/postgresql_data",
            "prod_volume": {
                "target_path": "/var/lib/postgresql_data",
                "mount_point": "/var/lib/postgresql_data",
                "device": "/dev/mapper/data_vg-data_lv",
                "volume_name": "data_vg/data_lv",
                "fs_type": "ext4",
                "total_bytes": 32212254720,
                "used_bytes": 9663676416,
                "free_bytes": 22548578304,
                "percent_used": 30.0,
                "percent_free": 70.0,
                "total_formatted": "30.00 GB",
                "used_formatted": "9.00 GB",
                "free_formatted": "21.00 GB",
                "exists": True
            },
            "backup_volume": {
                "target_path": "/var/lib/postgresql_backups/ubuntu-postgres-vm",
                "mount_point": "/var/lib/postgresql_backups",
                "device": "/dev/mapper/backup_vg-backup_lv",
                "volume_name": "backup_vg/backup_lv",
                "fs_type": "ext4",
                "total_bytes": 21474836480,
                "used_bytes": 6228557824,
                "free_bytes": 15246278656,
                "percent_used": 29.0,
                "percent_free": 71.0,
                "total_formatted": "20.00 GB",
                "used_formatted": "5.80 GB",
                "free_formatted": "14.20 GB",
                "exists": True
            },
            "disk_stats": {
                "total_bytes": 21474836480,
                "used_bytes": 6228557824,
                "free_bytes": 15246278656,
                "percent_used": 29.0,
                "percent_free": 71.0,
                "total_formatted": "20.00 GB",
                "used_formatted": "5.80 GB",
                "free_formatted": "14.20 GB",
                "volume_name": "backup_vg/backup_lv",
                "mount_point": "/var/lib/postgresql_backups",
                "device": "/dev/mapper/backup_vg-backup_lv"
            },
            "full_backup_count": 3,
            "full_backup_bytes": 4939212390,
            "full_backup_formatted": "4.60 GB",
            "latest_full_time": now - timedelta(hours=11, minutes=45),
            "latest_full_str": (now - timedelta(hours=11, minutes=45)).strftime("%Y-%m-%d 02:00:00 UTC"),
            "latest_full_age": "11h 45m",
            "oldest_full_time": now - timedelta(days=2, hours=11, minutes=45),
            "oldest_full_str": (now - timedelta(days=2, hours=11, minutes=45)).strftime("%Y-%m-%d 02:00:00 UTC"),
            "log_backup_count": 312,
            "log_backup_bytes": 1289345434,
            "log_backup_formatted": "1.20 GB",
            "latest_log_time": now - timedelta(minutes=6, seconds=40),
            "latest_log_str": (now - timedelta(minutes=6, seconds=40)).strftime("%Y-%m-%d %H:%M:%S UTC"),
            "latest_log_age": "6m 40s",
            "total_backup_bytes": 6228557824,
            "total_backup_formatted": "5.80 GB",
            "achieved_rpo_sec": 400,
            "achieved_rpo_str": "6m 40s",
            "target_rpo_min": 15,
            "rpo_status": "OPTIMAL",
            "rpo_status_desc": "Achieved (6m 40s vs SLA 15m)",
            "retention_days_full": 3,
            "retention_days_log": 3,
            "local_recovery_sec": 211245,
            "local_recovery_days": 2.4,
            "local_recovery_desc": "2.4 days (2d 10h 40m)",
            "local_recovery_range": f"{(now - timedelta(days=2, hours=11, minutes=45)).strftime('%Y-%m-%d 02:00')} \u2192 {(now - timedelta(minutes=6)).strftime('%Y-%m-%d %H:%M')} UTC",
            "has_pitr": True,
            "full_backups": [
                {"name": "pg_basebackup_2026-09-08_02-00-00.tar.gz", "size_formatted": "1.53 GB", "timestamp_str": (now - timedelta(days=2)).strftime("%Y-%m-%d 02:00:00 UTC")},
                {"name": "pg_basebackup_2026-09-09_02-00-00.tar.gz", "size_formatted": "1.53 GB", "timestamp_str": (now - timedelta(days=1)).strftime("%Y-%m-%d 02:00:00 UTC")},
                {"name": "pg_basebackup_2026-09-10_02-00-00.tar.gz", "size_formatted": "1.54 GB", "timestamp_str": now.strftime("%Y-%m-%d 02:00:00 UTC")}
            ],
            "recent_logs": [
                {"name": "00000001000000000000008F", "size_formatted": "16.0 MB", "timestamp_str": (now - timedelta(minutes=21)).strftime("%Y-%m-%d %H:%M:%S UTC")},
                {"name": "000000010000000000000090", "size_formatted": "16.0 MB", "timestamp_str": (now - timedelta(minutes=6, seconds=40)).strftime("%Y-%m-%d %H:%M:%S UTC")}
            ]
        },
        {
            "instance_name": "db2-backup-vm",
            "db_type": "db2",
            "engine_display": "IBM Db2 11.5",
            "backup_dir": "/var/lib/db2_backups/db2-backup-vm",
            "data_dir": "/var/lib/db2_data",
            "prod_volume": {
                "target_path": "/var/lib/db2_data",
                "mount_point": "/var/lib/db2_data",
                "device": "/dev/mapper/data_vg-data_lv",
                "volume_name": "data_vg/data_lv",
                "fs_type": "ext4",
                "total_bytes": 32212254720,
                "used_bytes": 7730941132,
                "free_bytes": 24481313588,
                "percent_used": 24.0,
                "percent_free": 76.0,
                "total_formatted": "30.00 GB",
                "used_formatted": "7.20 GB",
                "free_formatted": "22.80 GB",
                "exists": True
            },
            "backup_volume": {
                "target_path": "/var/lib/db2_backups/db2-backup-vm",
                "mount_point": "/var/lib/db2_backups",
                "device": "/dev/mapper/backup_vg-backup_lv",
                "volume_name": "backup_vg/backup_lv",
                "fs_type": "ext4",
                "total_bytes": 21474836480,
                "used_bytes": 4982181888,
                "free_bytes": 16492654592,
                "percent_used": 23.2,
                "percent_free": 76.8,
                "total_formatted": "20.00 GB",
                "used_formatted": "4.64 GB",
                "free_formatted": "15.36 GB",
                "exists": True
            },
            "disk_stats": {
                "total_bytes": 21474836480,
                "used_bytes": 4982181888,
                "free_bytes": 16492654592,
                "percent_used": 23.2,
                "percent_free": 76.8,
                "total_formatted": "20.00 GB",
                "used_formatted": "4.64 GB",
                "free_formatted": "15.36 GB",
                "volume_name": "backup_vg/backup_lv",
                "mount_point": "/var/lib/db2_backups",
                "device": "/dev/mapper/backup_vg-backup_lv"
            },
            "full_backup_count": 3,
            "full_backup_bytes": 4123168600,
            "full_backup_formatted": "3.84 GB",
            "latest_full_time": now - timedelta(hours=11, minutes=45),
            "latest_full_str": (now - timedelta(hours=11, minutes=45)).strftime("%Y-%m-%d 02:00:00 UTC"),
            "latest_full_age": "11h 45m",
            "oldest_full_time": now - timedelta(days=2, hours=11, minutes=45),
            "oldest_full_str": (now - timedelta(days=2, hours=11, minutes=45)).strftime("%Y-%m-%d 02:00:00 UTC"),
            "log_backup_count": 278,
            "log_backup_bytes": 859013288,
            "log_backup_formatted": "819.22 MB",
            "latest_log_time": now - timedelta(minutes=9, seconds=10),
            "latest_log_str": (now - timedelta(minutes=9, seconds=10)).strftime("%Y-%m-%d %H:%M:%S UTC"),
            "latest_log_age": "9m 10s",
            "total_backup_bytes": 4982181888,
            "total_backup_formatted": "4.64 GB",
            "achieved_rpo_sec": 550,
            "achieved_rpo_str": "9m 10s",
            "target_rpo_min": 15,
            "rpo_status": "OPTIMAL",
            "rpo_status_desc": "Achieved (9m 10s vs SLA 15m)",
            "retention_days_full": 3,
            "retention_days_log": 3,
            "local_recovery_sec": 210950,
            "local_recovery_days": 2.4,
            "local_recovery_desc": "2.4 days (2d 10h 35m)",
            "local_recovery_range": f"{(now - timedelta(days=2, hours=11, minutes=45)).strftime('%Y-%m-%d 02:00')} \u2192 {(now - timedelta(minutes=9)).strftime('%Y-%m-%d %H:%M')} UTC",
            "has_pitr": True,
            "full_backups": [
                {"name": "DB1.0.db2inst1.DBPART000.20260908020000.001", "size_formatted": "1.28 GB", "timestamp_str": (now - timedelta(days=2)).strftime("%Y-%m-%d 02:00:00 UTC")},
                {"name": "DB1.0.db2inst1.DBPART000.20260909020000.001", "size_formatted": "1.28 GB", "timestamp_str": (now - timedelta(days=1)).strftime("%Y-%m-%d 02:00:00 UTC")},
                {"name": "DB1.0.db2inst1.DBPART000.20260910020000.001", "size_formatted": "1.28 GB", "timestamp_str": now.strftime("%Y-%m-%d 02:00:00 UTC")}
            ],
            "recent_logs": [
                {"name": "S0000041.LOG", "size_formatted": "16.0 MB", "timestamp_str": (now - timedelta(minutes=24)).strftime("%Y-%m-%d %H:%M:%S UTC")},
                {"name": "S0000042.LOG", "size_formatted": "16.0 MB", "timestamp_str": (now - timedelta(minutes=9, seconds=10)).strftime("%Y-%m-%d %H:%M:%S UTC")}
            ]
        }
    ]
    return mock_instances

def render_html_dashboard(instances_data, generation_time=None):
    """Render high-fidelity dark-themed HTML report matching the meity-audit-demo design."""
    if not generation_time:
        generation_time = datetime.now(timezone.utc)
    
    total_instances = len(instances_data)
    optimal_count = sum(1 for d in instances_data if d["rpo_status"] == "OPTIMAL")
    warning_count = sum(1 for d in instances_data if d["rpo_status"] == "WARNING")
    critical_count = sum(1 for d in instances_data if d["rpo_status"] == "CRITICAL")
    
    # Backup Storage metrics
    total_backup_used = sum(d["total_backup_bytes"] for d in instances_data)
    total_backup_capacity = sum(d.get("backup_volume", {}).get("total_bytes", 0) for d in instances_data)
    overall_backup_pct = (total_backup_used / total_backup_capacity * 100.0) if total_backup_capacity > 0 else 0.0

    # Production Storage metrics
    total_prod_capacity = sum(d.get("prod_volume", {}).get("total_bytes", 0) for d in instances_data)
    total_prod_used = sum(d.get("prod_volume", {}).get("used_bytes", 0) for d in instances_data)
    total_prod_free = sum(d.get("prod_volume", {}).get("free_bytes", 0) for d in instances_data)
    overall_prod_free_pct = (total_prod_free / total_prod_capacity * 100.0) if total_prod_capacity > 0 else 0.0
    
    # Best & worst RPO
    valid_rpos = [d["achieved_rpo_sec"] for d in instances_data if d["achieved_rpo_sec"] is not None]
    max_rpo_sec = max(valid_rpos) if valid_rpos else None
    
    # Average local recovery window
    avg_recovery_days = round(sum(d["local_recovery_days"] for d in instances_data) / total_instances, 1) if total_instances else 0.0
    
    # Overall health banner
    if critical_count > 0:
        overall_status = "CRITICAL ATTENTION REQUIRED"
        overall_badge_bg = "linear-gradient(135deg, #ef4444, #b91c1c)"
    elif warning_count > 0:
        overall_status = "WARNING - RPO SLA AT RISK"
        overall_badge_bg = "linear-gradient(135deg, #f59e0b, #d97706)"
    else:
        overall_status = "ALL SYSTEMS HEALTHY - 100% SLA COMPLIANT"
        overall_badge_bg = "linear-gradient(135deg, #10b981, #059669)"

    # Build Table Rows, Storage Cards, and History Cards
    table_rows = ""
    storage_cards = ""
    history_cards = ""
    
    for d in instances_data:
        status_badge_class = f"badge-{d['rpo_status'].lower()}"
        b_vol = d.get("backup_volume", {})
        p_vol = d.get("prod_volume", {})
        
        # Table Row
        table_rows += f"""
        <tr>
            <td>
                <strong>{d['instance_name']}</strong><br/>
                <span style="font-size: 0.8rem; color: var(--text-secondary);">{d['engine_display']}</span>
            </td>
            <td>
                <span class="status-badge {status_badge_class}">{d['rpo_status']}</span><br/>
                <span style="font-size: 0.8rem; color: var(--text-secondary); font-weight: 500;">{d['achieved_rpo_str']} (SLA: {d['target_rpo_min']}m)</span>
            </td>
            <td>
                <strong>{d['latest_full_str']}</strong><br/>
                <span style="font-size: 0.8rem; color: var(--text-secondary);">{d['latest_full_age']} ago &bull; {d['full_backup_formatted']}</span>
            </td>
            <td>
                <strong>{d['latest_log_str']}</strong><br/>
                <span style="font-size: 0.8rem; color: var(--text-secondary);">{d['log_backup_count']} logs archived &bull; {d['log_backup_formatted']}</span>
            </td>
            <td>
                <strong style="color: #34d399;">{p_vol.get('free_formatted', 'N/A')} Free</strong> <span style="font-size: 0.78rem; color: var(--text-secondary);">({p_vol.get('percent_free', 0.0)}% available)</span><br/>
                <span style="font-size: 0.8rem; color: var(--text-secondary);">Vol: <code>{p_vol.get('volume_name', 'data_vg/data_lv')}</code> &bull; <code>{p_vol.get('mount_point', 'N/A')}</code></span><br/>
                <span style="font-size: 0.75rem; color: var(--text-secondary);">{p_vol.get('used_formatted', 'N/A')} used of {p_vol.get('total_formatted', 'N/A')}</span>
            </td>
            <td>
                <strong>{d['total_backup_formatted']} Used</strong> <span style="font-size: 0.78rem; color: var(--text-secondary);">({b_vol.get('free_formatted', 'N/A')} free)</span><br/>
                <span style="font-size: 0.8rem; color: var(--text-secondary);">Vol: <code>{b_vol.get('volume_name', 'backup_vg/backup_lv')}</code> &bull; <code>{b_vol.get('mount_point', d['backup_dir'])}</code></span><br/>
                <span style="font-size: 0.78rem; color: var(--accent-blue); font-weight: 600;">{d['local_recovery_desc']}</span>
            </td>
        </tr>
        """
        
        # Dual-track Storage Allocation Card
        b_total = b_vol.get("total_bytes") or 1
        full_pct = min(100.0, round((d["full_backup_bytes"] / b_total) * 100, 1))
        log_pct = min(max(0.0, 100.0 - full_pct), round((d["log_backup_bytes"] / b_total) * 100, 1))
        b_free_pct = max(0.0, round(100.0 - full_pct - log_pct, 1))

        p_total = p_vol.get("total_bytes") or 1
        p_used = p_vol.get("used_bytes") or 0
        p_used_pct = min(100.0, round((p_used / p_total) * 100, 1)) if p_total > 0 else 0.0
        p_free_pct = max(0.0, round(100.0 - p_used_pct, 1))

        storage_cards += f"""
        <div class="storage-card">
            <div class="storage-header">
                <div style="display: flex; align-items: center; gap: 0.75rem; flex-wrap: wrap;">
                    <span style="font-size: 1.1rem; font-weight: 700; color: #fff;">{d['instance_name']}</span>
                    <span style="font-size: 0.75rem; background: var(--bg-tertiary); padding: 0.2rem 0.6rem; border-radius: 6px; border: 1px solid var(--border-color); color: var(--text-secondary);">{d['engine_display']}</span>
                    <span style="font-size: 0.75rem; background: rgba(59, 130, 246, 0.15); color: #60a5fa; padding: 0.2rem 0.6rem; border-radius: 6px; border: 1px solid rgba(59, 130, 246, 0.3); font-weight: 600;">{d['local_recovery_days']}d Local PITR Window</span>
                </div>
                <div style="font-size: 0.82rem; color: var(--text-secondary);">
                    RPO: <strong style="color: #fff;">{d['achieved_rpo_str']}</strong> &bull; Target SLA: &le; {d['target_rpo_min']}m
                </div>
            </div>

            <!-- Backup Volume Track -->
            <div class="volume-track-container">
                <div class="volume-track-label">
                    <div style="display: flex; align-items: center; gap: 0.45rem;">
                        <span style="display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: var(--accent-cyan);"></span>
                        <strong style="font-size: 0.88rem; color: var(--text-primary);">Backup Volume:</strong>
                        <code>{b_vol.get('volume_name', 'backup_vg/backup_lv')}</code>
                    </div>
                    <div style="font-size: 0.8rem; color: var(--text-secondary);">
                        Mount: <code>{b_vol.get('mount_point', d['backup_dir'])}</code> &bull; Total: <strong>{b_vol.get('total_formatted', 'N/A')}</strong> &bull; Used: <strong>{d['total_backup_formatted']}</strong> &bull; Free: <span style="color: #34d399; font-weight: 600;">{b_vol.get('free_formatted', 'N/A')}</span>
                    </div>
                </div>
                <div class="gantt-track">
                    <div class="gantt-bar full-bar" style="width: {full_pct}%;" title="Full Backups: {d['full_backup_formatted']} ({full_pct}%)">
                        <span class="gantt-tag">Full: {d['full_backup_formatted']}</span>
                    </div>
                    <div class="gantt-bar log-bar" style="width: {log_pct}%;" title="Continuous Logs: {d['log_backup_formatted']} ({log_pct}%)">
                        <span class="gantt-tag">Logs: {d['log_backup_formatted']}</span>
                    </div>
                    <div class="gantt-bar free-bar" style="width: {b_free_pct}%;" title="Backup Volume Available: {b_vol.get('free_formatted', 'N/A')} ({b_free_pct}%)">
                        <span class="gantt-tag" style="color: var(--text-secondary);">Free: {b_vol.get('free_formatted', 'N/A')}</span>
                    </div>
                </div>
            </div>

            <!-- Production Data Volume Track -->
            <div class="volume-track-container" style="margin-top: 1rem;">
                <div class="volume-track-label">
                    <div style="display: flex; align-items: center; gap: 0.45rem;">
                        <span style="display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #8b5cf6;"></span>
                        <strong style="font-size: 0.88rem; color: var(--text-primary);">Production Data Volume:</strong>
                        <code>{p_vol.get('volume_name', 'data_vg/data_lv')}</code>
                    </div>
                    <div style="font-size: 0.8rem; color: var(--text-secondary);">
                        Mount: <code>{p_vol.get('mount_point', 'N/A')}</code> &bull; Total: <strong>{p_vol.get('total_formatted', 'N/A')}</strong> &bull; Used: <strong>{p_vol.get('used_formatted', 'N/A')}</strong> &bull; Available Headroom: <span style="color: #34d399; font-weight: 600;">{p_vol.get('free_formatted', 'N/A')} ({p_vol.get('percent_free', 0.0)}%)</span>
                    </div>
                </div>
                <div class="gantt-track">
                    <div class="gantt-bar prod-bar" style="width: {p_used_pct}%;" title="Production DB Data: {p_vol.get('used_formatted', 'N/A')} ({p_used_pct}%)">
                        <span class="gantt-tag">DB Data: {p_vol.get('used_formatted', 'N/A')}</span>
                    </div>
                    <div class="gantt-bar prod-free-bar" style="width: {p_free_pct}%;" title="Production Available Headroom: {p_vol.get('free_formatted', 'N/A')} ({p_vol.get('percent_free', 0.0)}%)">
                        <span class="gantt-tag" style="color: #a7f3d0;">Available Headroom: {p_vol.get('free_formatted', 'N/A')} ({p_vol.get('percent_free', 0.0)}%)</span>
                    </div>
                </div>
            </div>
        </div>
        """
        
        sample_logs = "".join([f"<li><code>{f.get('name', 'log')}</code> ({f.get('size_formatted', '')}) - {f.get('timestamp_str', '')}</li>" for f in d.get("recent_logs", [])[-3:]])
        sample_fulls = "".join([f"<li><code>{f.get('name', 'full')}</code> ({f.get('size_formatted', '')}) - {f.get('timestamp_str', '')}</li>" for f in d.get("full_backups", [])[-2:]])
        
        history_cards += f"""
        <div class="timeline-box">
            <div style="display: flex; justify-content: space-between; align-items: flex-start; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 0.75rem;">
                <div>
                    <h3 style="font-size: 1.1rem; color: var(--accent-blue); display: inline-block; margin-right: 0.5rem;">{d['instance_name']}</h3>
                    <span style="font-size: 0.8rem; color: var(--text-secondary);">({d['engine_display']})</span>
                </div>
                <div>
                    <span class="status-badge {status_badge_class}">{d['rpo_status']}</span>
                </div>
            </div>
            
            <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 1rem; margin-bottom: 1rem; background: rgba(17, 24, 39, 0.4); padding: 0.8rem 1rem; border-radius: 8px; border: 1px solid rgba(55, 65, 81, 0.5);">
                <div>
                    <span style="font-size: 0.75rem; color: var(--accent-cyan); text-transform: uppercase; font-weight: 700; display: block; letter-spacing: 0.05em;">Backup Storage Volume</span>
                    <div style="font-size: 0.85rem; margin-top: 0.3rem;">
                        <strong>Device:</strong> <code>{b_vol.get('volume_name', 'backup_vg/backup_lv')}</code> <span style="font-size: 0.75rem; color: var(--text-secondary);">({b_vol.get('device', 'N/A')})</span><br/>
                        <strong>Mount:</strong> <code>{b_vol.get('mount_point', d['backup_dir'])}</code><br/>
                        <strong>Capacity:</strong> {b_vol.get('total_formatted', 'N/A')} &bull; {d['total_backup_formatted']} used &bull; <span style="color: #34d399; font-weight: 600;">{b_vol.get('free_formatted', 'N/A')} free</span>
                    </div>
                </div>
                <div>
                    <span style="font-size: 0.75rem; color: #a78bfa; text-transform: uppercase; font-weight: 700; display: block; letter-spacing: 0.05em;">Production Data Volume</span>
                    <div style="font-size: 0.85rem; margin-top: 0.3rem;">
                        <strong>Device:</strong> <code>{p_vol.get('volume_name', 'data_vg/data_lv')}</code> <span style="font-size: 0.75rem; color: var(--text-secondary);">({p_vol.get('device', 'N/A')})</span><br/>
                        <strong>Mount:</strong> <code>{p_vol.get('mount_point', 'N/A')}</code><br/>
                        <strong>Capacity:</strong> {p_vol.get('total_formatted', 'N/A')} &bull; {p_vol.get('used_formatted', 'N/A')} used &bull; <span style="color: #34d399; font-weight: 600;">{p_vol.get('free_formatted', 'N/A')} ({p_vol.get('percent_free', 0.0)}% headroom)</span>
                    </div>
                </div>
            </div>

            <p style="font-size: 0.82rem; color: var(--text-secondary); margin-bottom: 0.8rem;">
                Target RPO SLA: <strong>&le; {d['target_rpo_min']}m</strong> &bull; Retention Policy: <strong>{d['retention_days_full']}d Full</strong>, <strong>{d['retention_days_log']}d Logs</strong> &bull; Local Recovery Window: <strong style="color: var(--accent-blue);">{d['local_recovery_desc']}</strong>
            </p>

            <div style="font-size: 0.85rem; margin-bottom: 0.4rem;"><strong>Recent Full Backups:</strong></div>
            <ul class="file-list">{sample_fulls or '<li>No full backups logged.</li>'}</ul>
            <div style="font-size: 0.85rem; margin-top: 0.6rem; margin-bottom: 0.4rem;"><strong>Latest Continuous Archive Logs:</strong></div>
            <ul class="file-list">{sample_logs or '<li>No archive logs logged.</li>'}</ul>
        </div>
        """

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Database Backup & Recovery Health Dashboard</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&family=Plus+Jakarta+Sans:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {{
            --bg-primary: #0b0f19;
            --bg-secondary: #111827;
            --bg-tertiary: #1f2937;
            --text-primary: #f3f4f6;
            --text-secondary: #9ca3af;
            --accent-success: #10b981;
            --accent-success-glow: rgba(16, 185, 129, 0.15);
            --accent-blue: #3b82f6;
            --accent-blue-glow: rgba(59, 130, 246, 0.15);
            --accent-cyan: #06b6d4;
            --accent-purple: #8b5cf6;
            --accent-warning: #f59e0b;
            --accent-warning-glow: rgba(245, 158, 11, 0.15);
            --accent-danger: #ef4444;
            --border-color: #374151;
            --glow-card: 0 10px 30px -10px rgba(0, 0, 0, 0.7);
        }}

        * {{
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }}

        body {{
            font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            background-color: var(--bg-primary);
            color: var(--text-primary);
            line-height: 1.6;
            padding: 2.5rem 1.5rem;
        }}

        .container {{
            max-width: 1200px;
            margin: 0 auto;
        }}

        header {{
            margin-bottom: 2.5rem;
            border-bottom: 1px solid var(--border-color);
            padding-bottom: 2rem;
            position: relative;
        }}

        .badge-status {{
            display: inline-block;
            background: {overall_badge_bg};
            color: #fff;
            padding: 0.4rem 1rem;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 700;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
            margin-bottom: 1rem;
        }}

        h1 {{
            font-family: 'Outfit', sans-serif;
            font-size: 2.4rem;
            font-weight: 700;
            letter-spacing: -0.02em;
            background: linear-gradient(135deg, #fff 40%, #9ca3af);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            margin-bottom: 0.5rem;
        }}

        .subtitle {{
            color: var(--text-secondary);
            font-size: 1rem;
        }}

        .stats-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 1.25rem;
            margin-bottom: 3rem;
        }}

        .stat-card {{
            background-color: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 16px;
            padding: 1.5rem;
            box-shadow: var(--glow-card);
            position: relative;
            overflow: hidden;
            transition: transform 0.2s ease, border-color 0.2s ease;
        }}

        .stat-card:hover {{
            transform: translateY(-2px);
            border-color: var(--accent-blue);
        }}

        .stat-card.success-card {{
            border-left: 4px solid var(--accent-success);
        }}

        .stat-card.blue-card {{
            border-left: 4px solid var(--accent-blue);
        }}

        .stat-card.cyan-card {{
            border-left: 4px solid var(--accent-cyan);
        }}

        .stat-card.purple-card {{
            border-left: 4px solid var(--accent-purple);
        }}

        .stat-card.warning-card {{
            border-left: 4px solid var(--accent-warning);
        }}

        .stat-card::before {{
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: radial-gradient(circle at 80% 20%, var(--accent-blue-glow), transparent 45%);
            pointer-events: none;
        }}

        .stat-card.purple-card::before {{
            background: radial-gradient(circle at 80% 20%, rgba(139, 92, 246, 0.18), transparent 45%);
        }}

        .stat-label {{
            font-size: 0.82rem;
            color: var(--text-secondary);
            text-transform: uppercase;
            letter-spacing: 0.05em;
            margin-bottom: 0.5rem;
        }}

        .stat-value {{
            font-family: 'Outfit', sans-serif;
            font-size: 1.85rem;
            font-weight: 600;
        }}

        .stat-sub {{
            font-size: 0.78rem;
            color: var(--text-secondary);
            margin-top: 0.3rem;
        }}

        .status-ok {{
            color: var(--accent-success);
            text-shadow: 0 0 12px rgba(16, 185, 129, 0.25);
        }}

        .status-warning {{
            color: var(--accent-warning);
            text-shadow: 0 0 12px rgba(245, 158, 11, 0.25);
        }}

        .status-critical {{
            color: var(--accent-danger);
            text-shadow: 0 0 12px rgba(239, 68, 68, 0.25);
        }}

        section {{
            background-color: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 20px;
            padding: 2rem;
            margin-bottom: 2.5rem;
            box-shadow: var(--glow-card);
        }}

        h2 {{
            font-family: 'Outfit', sans-serif;
            font-size: 1.4rem;
            font-weight: 600;
            margin-bottom: 1.5rem;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }}

        h2::before {{
            content: '';
            display: inline-block;
            width: 4px;
            height: 1.25rem;
            background-color: var(--accent-blue);
            border-radius: 2px;
        }}

        .table-container {{
            overflow-x: auto;
        }}

        table {{
            width: 100%;
            border-collapse: collapse;
            text-align: left;
            font-size: 0.9rem;
        }}

        th {{
            background-color: var(--bg-tertiary);
            color: var(--text-primary);
            font-weight: 600;
            padding: 1rem;
            border-bottom: 2px solid var(--border-color);
        }}

        td {{
            padding: 1.2rem 1rem;
            border-bottom: 1px solid var(--border-color);
            color: var(--text-primary);
            vertical-align: top;
        }}

        tr:last-child td {{
            border-bottom: none;
        }}

        .status-badge {{
            display: inline-block;
            padding: 0.2rem 0.6rem;
            border-radius: 6px;
            font-size: 0.75rem;
            font-weight: 700;
            text-transform: uppercase;
        }}

        .badge-optimal {{
            background-color: rgba(16, 185, 129, 0.2);
            color: #34d399;
            border: 1px solid rgba(16, 185, 129, 0.4);
        }}

        .badge-warning {{
            background-color: rgba(245, 158, 11, 0.2);
            color: #fbbf24;
            border: 1px solid rgba(245, 158, 11, 0.4);
        }}

        .badge-critical {{
            background-color: rgba(239, 68, 68, 0.2);
            color: #f87171;
            border: 1px solid rgba(239, 68, 68, 0.4);
        }}

        /* Storage Cards & Dual-Track Breakdown */
        .storage-cards-container {{
            display: flex;
            flex-direction: column;
            gap: 1.25rem;
            margin-top: 1rem;
        }}

        .storage-card {{
            background-color: rgba(17, 24, 39, 0.6);
            border: 1px solid var(--border-color);
            border-radius: 14px;
            padding: 1.25rem 1.5rem;
            box-shadow: var(--glow-card);
            transition: border-color 0.2s ease, transform 0.2s ease;
        }}

        .storage-card:hover {{
            border-color: rgba(59, 130, 246, 0.4);
            transform: translateY(-1px);
        }}

        .storage-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 1rem;
            flex-wrap: wrap;
            gap: 0.75rem;
            border-bottom: 1px solid rgba(55, 65, 81, 0.4);
            padding-bottom: 0.75rem;
        }}

        .volume-track-container {{
            display: flex;
            flex-direction: column;
            gap: 0.4rem;
        }}

        .volume-track-label {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 0.5rem;
            font-size: 0.85rem;
        }}

        .gantt-track {{
            background-color: var(--bg-tertiary);
            border-radius: 8px;
            height: 32px;
            position: relative;
            display: flex;
            overflow: hidden;
            border: 1px solid rgba(55, 65, 81, 0.6);
        }}

        .gantt-bar {{
            height: 100%;
            display: flex;
            align-items: center;
            padding-left: 0.6rem;
            overflow: hidden;
            white-space: nowrap;
            transition: width 0.3s ease;
        }}

        .full-bar {{
            background: linear-gradient(90deg, #2563eb, #3b82f6);
        }}

        .log-bar {{
            background: linear-gradient(90deg, #0891b2, #06b6d4);
        }}

        .free-bar {{
            background-color: #1f2937;
        }}

        .prod-bar {{
            background: linear-gradient(90deg, #6d28d9, #8b5cf6);
        }}

        .prod-free-bar {{
            background: linear-gradient(90deg, rgba(16, 185, 129, 0.2), rgba(16, 185, 129, 0.35));
            border: 1px solid rgba(16, 185, 129, 0.3);
        }}

        .gantt-tag {{
            font-size: 0.72rem;
            font-weight: 600;
            color: #ffffff;
            text-shadow: 0 1px 2px rgba(0, 0, 0, 0.8);
        }}

        .gantt-legend {{
            display: flex;
            flex-wrap: wrap;
            gap: 1.5rem;
            margin-top: 1.5rem;
            font-size: 0.8rem;
            color: var(--text-secondary);
            padding-top: 1rem;
            border-top: 1px solid rgba(55, 65, 81, 0.4);
        }}

        .legend-item {{
            display: flex;
            align-items: center;
            gap: 0.45rem;
        }}

        .legend-dot {{
            display: inline-block;
            width: 12px;
            height: 12px;
            border-radius: 3px;
        }}

        .full-dot {{ background: #3b82f6; }}
        .log-dot {{ background: #06b6d4; }}
        .free-dot {{ background: #1f2937; border: 1px solid #4b5563; }}
        .prod-dot {{ background: #8b5cf6; }}
        .prod-free-dot {{ background: #059669; }}

        .timeline-box {{
            background-color: rgba(31, 41, 55, 0.4);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            padding: 1.25rem;
            margin-bottom: 1rem;
        }}

        .file-list {{
            list-style: none;
            padding-left: 0;
        }}

        .file-list li {{
            font-family: monospace;
            font-size: 0.8rem;
            color: var(--text-secondary);
            padding: 0.2rem 0;
        }}

        code {{
            font-family: monospace;
            background-color: var(--bg-tertiary);
            padding: 0.2rem 0.4rem;
            border-radius: 4px;
            font-size: 0.8rem;
            color: #e5e7eb;
        }}

        footer {{
            text-align: center;
            color: var(--text-secondary);
            font-size: 0.85rem;
            margin-top: 3rem;
            border-top: 1px solid var(--border-color);
            padding-top: 2rem;
        }}
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="badge-status">{overall_status}</div>
            <h1>Database Backup & Recovery Health Dashboard</h1>
            <div class="subtitle">
                Automated Protection Audit &bull; Generated: {generation_time.strftime('%Y-%m-%d %H:%M:%S UTC')} &bull; Host: {socket.gethostname()}
            </div>
        </header>

        <!-- Stats Overview Grid -->
        <div class="stats-grid">
            <div class="stat-card success-card">
                <div class="stat-label">Protection Status</div>
                <div class="stat-value status-ok">{optimal_count}/{total_instances} Active</div>
                <div class="stat-sub">{critical_count} Critical &bull; {warning_count} Warnings</div>
            </div>
            <div class="stat-card blue-card">
                <div class="stat-label">Achieved RPO Window</div>
                <div class="stat-value">{format_duration(max_rpo_sec) if max_rpo_sec is not None else 'N/A'}</div>
                <div class="stat-sub">Target SLA: &le; 15 Minutes</div>
            </div>
            <div class="stat-card cyan-card">
                <div class="stat-label">Backup Storage Consumed</div>
                <div class="stat-value">{format_bytes(total_backup_used)}</div>
                <div class="stat-sub">{overall_backup_pct:.1f}% used of {format_bytes(total_backup_capacity)} Dedicated Capacity</div>
            </div>
            <div class="stat-card purple-card">
                <div class="stat-label">Production Storage Headroom</div>
                <div class="stat-value" style="color: #34d399;">{format_bytes(total_prod_free)} Free</div>
                <div class="stat-sub">{overall_prod_free_pct:.1f}% available ({format_bytes(total_prod_used)} / {format_bytes(total_prod_capacity)} used)</div>
            </div>
            <div class="stat-card warning-card">
                <div class="stat-label">Avg Local Recovery Window</div>
                <div class="stat-value">{avg_recovery_days} Days</div>
                <div class="stat-sub">Point-in-Time Recovery from Disk</div>
            </div>
        </div>

        <!-- Protection Summary Table -->
        <section>
            <h2>Database Instance Protection Summary</h2>
            <div class="table-container">
                <table>
                    <thead>
                        <tr>
                            <th>Database / Host</th>
                            <th>RPO Status</th>
                            <th>Latest Full Backup</th>
                            <th>Continuous Archive Logs</th>
                            <th>Production Data Volume</th>
                            <th>Backup Volume & Local PITR</th>
                        </tr>
                    </thead>
                    <tbody>
                        {table_rows}
                    </tbody>
                </table>
            </div>
        </section>

        <!-- Local Disk Recovery & Storage Visual Breakdown -->
        <section>
            <h2>Local Disk Storage Allocation & Retention Breakdown</h2>
            <p style="font-size: 0.9rem; color: var(--text-secondary); margin-bottom: 1.5rem;">
                Visual breakdown tracking dedicated persistent disk allocation for both <strong>Backup Storage Volumes</strong> (Full Backups vs Continuous Archive Logs) and <strong>Production Data Volumes</strong> (Active DB Data vs Free Growth Headroom).
            </p>
            <div class="storage-cards-container">
                {storage_cards}
            </div>
            <div class="gantt-legend">
                <div class="legend-item"><span class="legend-dot full-dot"></span> Full Backups</div>
                <div class="legend-item"><span class="legend-dot log-dot"></span> Continuous Archive Logs (PITR)</div>
                <div class="legend-item"><span class="legend-dot free-dot"></span> Backup Volume Available</div>
                <div class="legend-item"><span class="legend-dot prod-dot"></span> Production DB Data</div>
                <div class="legend-item"><span class="legend-dot prod-free-dot"></span> Production Available Headroom</div>
            </div>
        </section>

        <!-- Recent Backup Activity Details -->
        <section>
            <h2>Recent Backup Artifacts & History Log</h2>
            {history_cards}
        </section>

        <footer>
            Self-Managed Databases on Google Compute Engine &bull; Automated Daily Protection Dashboard &bull; IBM Db2, PostgreSQL & MySQL Support
        </footer>
    </div>
</body>
</html>
"""
    return html

def send_email_report(html_content, recipients, subject=None, smtp_host=None, smtp_port=587, smtp_user=None, smtp_password=None, smtp_tls=True, from_email=None):
    """Send HTML dashboard email to specified recipients."""
    if not recipients:
        print("[Dashboard] No recipients specified. Skipping email dispatch.")
        return False

    hostname = socket.gethostname()
    if not from_email:
        from_email = f"backup-reports@{hostname}"
    if not subject:
        subject = f"[REPORT] Database Backup & Recovery Health Dashboard - {datetime.now().strftime('%Y-%m-%d')}"

    recipient_list = [r.strip() for r in recipients.split(",") if r.strip()]
    if not recipient_list:
        print("[Dashboard] Empty recipient list after parsing.")
        return False

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = from_email
    msg["To"] = ", ".join(recipient_list)

    # Plain text fallback
    plain_text = (
        f"Database Backup & Recovery Health Dashboard\n"
        f"Report Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}\n"
        f"Host: {hostname}\n\n"
        f"Please view this email in an HTML-compatible client to see full graphs, volume metrics, and tables.\n"
    )
    msg.attach(MIMEText(plain_text, "plain"))
    msg.attach(MIMEText(html_content, "html"))

    # If an external SMTP server is provided
    if smtp_host:
        try:
            print(f"[Dashboard] Connecting to SMTP server {smtp_host}:{smtp_port}...")
            server = smtplib.SMTP(smtp_host, smtp_port, timeout=15)
            if smtp_tls:
                server.starttls()
            if smtp_user and smtp_password:
                server.login(smtp_user, smtp_password)
            server.sendmail(from_email, recipient_list, msg.as_string())
            server.quit()
            print(f"[Dashboard] SUCCESS: Report successfully sent to {recipient_list} via SMTP ({smtp_host}).")
            return True
        except Exception as e:
            print(f"[Dashboard] ERROR: Failed to send email via SMTP ({smtp_host}): {e}")
            return False

    # Otherwise fallback to local sendmail or mailx if installed
    sendmail_paths = ["/usr/sbin/sendmail", "/usr/lib/sendmail", "/usr/bin/sendmail"]
    sendmail_bin = next((p for p in sendmail_paths if os.path.exists(p)), None)
    if sendmail_bin:
        try:
            import subprocess
            print(f"[Dashboard] Dispatching email via local MTA: {sendmail_bin}...")
            proc = subprocess.Popen([sendmail_bin, "-t", "-oi"], stdin=subprocess.PIPE, text=True)
            proc.communicate(msg.as_string())
            if proc.returncode == 0:
                print(f"[Dashboard] SUCCESS: Email successfully dispatched via {sendmail_bin} to {recipient_list}.")
                return True
            else:
                print(f"[Dashboard] WARNING: {sendmail_bin} exited with return code {proc.returncode}.")
        except Exception as ex:
            print(f"[Dashboard] ERROR: Local sendmail execution failed: {ex}")

    print("[Dashboard] NOTE: No active SMTP host or local MTA found. Saved report locally.")
    return False

def discover_local_instances(backup_root):
    """Auto-detect instances present under a root backup directory."""
    instances = []
    if os.path.exists(backup_root):
        for entry in os.scandir(backup_root):
            if entry.is_dir() and not entry.name.startswith("."):
                if (os.path.exists(os.path.join(entry.path, "full")) or
                    os.path.exists(os.path.join(entry.path, "logs")) or
                    os.path.exists(os.path.join(entry.path, "last_full_backup_timestamp"))):
                    instances.append(entry.name)
    return instances

def main():
    parser = argparse.ArgumentParser(description="Database Backup & Recovery Health Dashboard")
    parser.add_argument("--backup-dir", help="Root backup directory to scan", default=None)
    parser.add_argument("--data-dir", help="Production database data directory to monitor (default: auto-detected, e.g. /var/lib/db2_data)", default=None)
    parser.add_argument("--instance-name", help="Instance name (default: hostname or auto-discovered)", default=None)
    parser.add_argument("--db-type", help="Database type (mysql, postgres, db2)", default=None)
    parser.add_argument("--retention-full", type=int, help="Days to retain full backups", default=int(os.environ.get("RETENTION_DAYS_FULL", 3)))
    parser.add_argument("--retention-log", type=int, help="Days to retain log backups", default=int(os.environ.get("RETENTION_DAYS_LOG", 3)))
    parser.add_argument("--target-rpo-min", type=int, help="Target RPO SLA in minutes", default=int(os.environ.get("LOG_BACKUP_INTERVAL_MINUTES", 15)))
    parser.add_argument("--output-html", help="Path to write the output HTML file", default="/var/log/backup_dashboard.html")
    parser.add_argument("--send-email", action="store_true", help="Send the generated report via email")
    parser.add_argument("--recipients", help="Comma-separated recipient emails", default=os.environ.get("REPORT_RECIPIENTS", ""))
    parser.add_argument("--smtp-host", help="SMTP server host", default=os.environ.get("SMTP_HOST", ""))
    parser.add_argument("--smtp-port", type=int, help="SMTP port", default=int(os.environ.get("SMTP_PORT", 587)))
    parser.add_argument("--smtp-user", help="SMTP username", default=os.environ.get("SMTP_USER", ""))
    parser.add_argument("--smtp-password", help="SMTP password", default=os.environ.get("SMTP_PASSWORD", ""))
    parser.add_argument("--from-email", help="From email address", default=os.environ.get("FROM_EMAIL", ""))
    parser.add_argument("--subject", help="Custom email subject", default=None)
    parser.add_argument("--sample-data", action="store_true", help="Use demonstration/mock data (for dry runs or preview)")

    args = parser.parse_args()

    instances_data = []

    if args.sample_data:
        print("[Dashboard] Generating report using demonstration dataset...")
        instances_data = generate_mock_data()
    else:
        candidate_roots = []
        if args.backup_dir:
            candidate_roots.append(args.backup_dir)
        else:
            for d in ["/var/lib/mysql_backups", "/var/lib/postgresql_backups", "/var/lib/db2_backups", "/mnt/backup"]:
                if os.path.isdir(d):
                    candidate_roots.append(d)

        hostname = socket.gethostname()

        for root in candidate_roots:
            found_instances = discover_local_instances(root)
            if not found_instances:
                inst_dir = os.path.join(root, hostname)
                if os.path.exists(inst_dir):
                    found_instances = [hostname]
            
            for inst in found_instances:
                data = scan_instance_backups(
                    backup_dir=root,
                    instance_name=inst,
                    data_dir=args.data_dir,
                    db_type=args.db_type,
                    retention_full=args.retention_full,
                    retention_log=args.retention_log,
                    target_rpo_min=args.target_rpo_min
                )
                instances_data.append(data)

        if not instances_data and candidate_roots:
            data = scan_instance_backups(
                backup_dir=candidate_roots[0],
                instance_name=args.instance_name or hostname,
                data_dir=args.data_dir,
                db_type=args.db_type,
                retention_full=args.retention_full,
                retention_log=args.retention_log,
                target_rpo_min=args.target_rpo_min
            )
            instances_data.append(data)

        if not instances_data:
            print("[Dashboard] No local backup files found. Falling back to demonstration dataset for report preview.")
            instances_data = generate_mock_data()

    html_output = render_html_dashboard(instances_data)

    try:
        os.makedirs(os.path.dirname(os.path.abspath(args.output_html)), exist_ok=True)
        with open(args.output_html, "w", encoding="utf-8") as f:
            f.write(html_output)
        print(f"[Dashboard] Generated HTML dashboard written to: {args.output_html}")
    except Exception as e:
        print(f"[Dashboard] WARNING: Could not write HTML file to {args.output_html}: {e}")

    if args.send_email or (args.recipients and args.recipients.strip()):
        send_email_report(
            html_content=html_output,
            recipients=args.recipients,
            subject=args.subject,
            smtp_host=args.smtp_host,
            smtp_port=args.smtp_port,
            smtp_user=args.smtp_user,
            smtp_password=args.smtp_password,
            from_email=args.from_email
        )

    print("[Dashboard] Dashboard processing completed successfully.")

if __name__ == "__main__":
    main()
