#!/bin/bash
set -eo pipefail

# ==============================================================================
# Database Backup Script
# ==============================================================================
# This script handles scheduled backups for MySQL and PostgreSQL.
# It supports:
# - Full Backups (Snapshot/Dump)
# - Log Backups (Binlogs/WALs)
# - Time-based retention
# - Hierarchical storage structure
#
# It is designed to be triggered by cron (e.g., every 15 minutes).
# ==============================================================================

# --- Configuration (Defaults) ---
BACKUP_ROOT="${BACKUP_DIR:-/mnt/backup}"
RETENTION_DAYS="${RETENTION_DAYS:-3}"
FULL_BACKUP_INTERVAL_HOURS="${FULL_BACKUP_INTERVAL_HOURS:-24}"
# DB_TYPE must be set to 'mysql' or 'postgres'
DB_TYPE="${DB_TYPE:-mysql}" 
# Optional credential inputs if not using .my.cnf or .pgpass (Preferred to use Env/Connect files)

# --- Derived Config ---
# Defaults to hostname if not provided
INSTANCE_NAME="${INSTANCE_NAME:-$(hostname)}"

# --- Derived Config ---
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
DATE_DIR=$(date +"%Y-%m-%d")
# Hierarchy: $BACKUP_ROOT/$INSTANCE_NAME/{full,logs}/$DATE_DIR
FULL_BACKUP_DIR="${BACKUP_ROOT}/${INSTANCE_NAME}/full/${DATE_DIR}"
LOG_BACKUP_DIR="${BACKUP_ROOT}/${INSTANCE_NAME}/logs/${DATE_DIR}"
LAST_FULL_BACKUP_FILE="${BACKUP_ROOT}/${INSTANCE_NAME}/last_full_backup_timestamp"

# --- Setup Directories ---
mkdir -p "$FULL_BACKUP_DIR"
mkdir -p "$LOG_BACKUP_DIR"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

should_run_full_backup() {
    if [ ! -f "$LAST_FULL_BACKUP_FILE" ]; then
        log "No previous full backup found. Scheduling full backup."
        return 0 # True
    fi
    
    local last_timestamp
    last_timestamp=$(cat "$LAST_FULL_BACKUP_FILE")
    local current_timestamp
    current_timestamp=$(date +%s)
    local diff_sec=$((current_timestamp - last_timestamp))
    local interval_sec=$((FULL_BACKUP_INTERVAL_HOURS * 3600))
    
    if [ "$diff_sec" -ge "$interval_sec" ]; then
        log "Full backup interval ($FULL_BACKUP_INTERVAL_HOURS hours) reached. Scheduling full backup."
        return 0 # True
    else
        log "Recent full backup exists ($((diff_sec / 60)) minutes ago). Scheduling log backup."
        return 1 # False
    fi
}

perform_mysql_full() {
    log "Starting MySQL Full Backup..."
    # --single-transaction: Consistent backup for InnoDB without locking
    # --flush-logs: Rotate logs at start of backup
    # --master-data=2: Include binlog coordinates for PITR
    # --all-databases: Backup everything
    mysqldump --defaults-extra-file=/root/.my.cnf --all-databases --single-transaction --flush-logs --master-data=2 --triggers --routines --events | gzip > "${FULL_BACKUP_DIR}/mysql_full_${TIMESTAMP}.sql.gz"
    
    if [ $? -eq 0 ]; then
        log "MySQL Full Backup completed successfully."
        date +%s > "$LAST_FULL_BACKUP_FILE"
    else
        log "ERROR: MySQL Full Backup failed."
        exit 1
    fi
}

perform_mysql_log() {
    log "Starting MySQL Log Backup..."
    # Flush logs to trigger rotation
    mysql --defaults-extra-file=/root/.my.cnf -e "FLUSH BINARY LOGS;"
    
    # Copy all binary logs. 
    # Assumption: /var/lib/mysql is the data dir. 
    # We use rsync to copy logs. We might copy active logs too, but that's safe-ish if we just need the file.
    # Better to copy all "binlog.*" files.
    # NOTE: This assumes standard binlog naming. Adjust if 'mysql-bin' prefix starts differing.
    
    # We just rsync additively.
    rsync -av /var/lib/mysql/binlog.* "${LOG_BACKUP_DIR}/"
    log "MySQL Log Backup completed."
}

perform_postgres_full() {
    log "Starting Postgres Full Backup..."
    # pg_basebackup produces a binary copy of the cluster files.
    # -F t: Tar format
    # -z: Gzip compressed
    # -X fetch: Include WAL files needed for the backup
    # -D: Destination directory
    # Run as postgres user to avoid auth issues (ident/peer)
    sudo -u postgres pg_basebackup -D "${FULL_BACKUP_DIR}/pg_basebackup_${TIMESTAMP}" -Ft -z -X fetch
    
    if [ $? -eq 0 ]; then
        log "Postgres Full Backup completed successfully."
        date +%s > "$LAST_FULL_BACKUP_FILE"
    else
        log "ERROR: Postgres Full Backup failed."
        exit 1
    fi
}

perform_postgres_log() {
    log "Starting Postgres Log Backup..."
    # Force a WAL switch to ensure the current segment is ready for archiving
    sudo -u postgres psql -c "SELECT pg_switch_wal();"
    
    # In our setup, we configure archive_command to move files to a staging dir.
    # We will assume a convention or config for this.
    # Let's use "${BACKUP_ROOT}/${INSTANCE_NAME}/wal_staging" to match the new structure.
    local staging_dir="${BACKUP_ROOT}/${INSTANCE_NAME}/wal_staging"
    
    if [ -d "$staging_dir" ]; then
        # Move archived WALs to backup dir
        # We use rsync --remove-source-files to 'move' effectively but safely
        # Check if dir is empty first to avoid rsync errors on empty source list?
        if [ "$(ls -A $staging_dir)" ]; then
             rsync -av --remove-source-files "$staging_dir/" "${LOG_BACKUP_DIR}/"
             log "Moved WAL/Archive files to backup storage."
        else
             log "No WAL files found in staging area."
        fi
    else
        log "WARNING: Archive staging directory $staging_dir not found."
    fi
}

cleanup_retention() {
    log "Running retention cleanup (Retention: ${RETENTION_DAYS} days)..."
    
    # Find directories (YYYY-MM-DD) older than retention days and remove them
    # We look inside $INSTANCE_NAME/full/ and $INSTANCE_NAME/logs/
    
    find "${BACKUP_ROOT}/${INSTANCE_NAME}/full" -mindepth 1 -maxdepth 1 -type d -mtime +"${RETENTION_DAYS}" -print -exec rm -rf {} +
    find "${BACKUP_ROOT}/${INSTANCE_NAME}/logs" -mindepth 1 -maxdepth 1 -type d -mtime +"${RETENTION_DAYS}" -print -exec rm -rf {} +
    
    log "Cleanup completed."
}

# --- Main Execution ---

if should_run_full_backup; then
    if [ "$DB_TYPE" == "mysql" ]; then
        perform_mysql_full
    elif [ "$DB_TYPE" == "postgres" ]; then
        perform_postgres_full
    fi
else
    if [ "$DB_TYPE" == "mysql" ]; then
        perform_mysql_log
    elif [ "$DB_TYPE" == "postgres" ]; then
        perform_postgres_log
    fi
fi

cleanup_retention
