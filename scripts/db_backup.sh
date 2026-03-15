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
# BACKUP_MODE can be 'auto' (default), 'full', or 'log'
BACKUP_MODE="${BACKUP_MODE:-auto}"
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

# --- Establish Owner ---
if [ "$DB_TYPE" == "postgres" ]; then
    BACKUP_USER="postgres"
    BACKUP_GROUP="postgres"
else
    BACKUP_USER="mysql"
    BACKUP_GROUP="mysql"
fi

# --- Setup Directories ---
mkdir -p "$FULL_BACKUP_DIR"
mkdir -p "$LOG_BACKUP_DIR"
chown -R "${BACKUP_USER}:${BACKUP_GROUP}" "${BACKUP_ROOT}/${INSTANCE_NAME}"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

should_run_full_backup() {
    if [ "$BACKUP_MODE" == "full" ]; then
        log "Forced full backup mode enabled."
        return 0 # True
    elif [ "$BACKUP_MODE" == "log" ]; then
        log "Forced log backup mode enabled."
        return 1 # False
    fi

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
    
    log "Checking Full Backup Status:"
    log "  Last Full Backup: $last_timestamp ($(date -d @$last_timestamp))"
    log "  Current Time:     $current_timestamp ($(date -d @$current_timestamp))"
    log "  Diff:             $diff_sec seconds"
    log "  Interval:         $interval_sec seconds ($FULL_BACKUP_INTERVAL_HOURS hours)"

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
    
    local marker_file="${BACKUP_ROOT}/${INSTANCE_NAME}/last_mysql_log_run"
    
    # Dynamically find binlog basename and index
    local log_bin_basename
    log_bin_basename=$(mysql --defaults-extra-file=/root/.my.cnf -NBe "SELECT @@log_bin_basename;" 2>/dev/null || true)
    local log_bin_index
    log_bin_index=$(mysql --defaults-extra-file=/root/.my.cnf -NBe "SELECT @@log_bin_index;" 2>/dev/null || true)

    # Fallback to defaults if variables are empty (e.g. if SQL fails or variables not supported)
    if [ -z "$log_bin_basename" ]; then
        log "WARNING: Could not determine log_bin_basename via SQL. Falling back to /var/lib/mysql/mysql-bin"
        log_bin_basename="/var/lib/mysql/mysql-bin"
    fi
    if [ -z "$log_bin_index" ]; then
        log_bin_index="/var/lib/mysql/mysql-bin.index"
    fi

    # Resolve any symlinks to get the real directory path (crucial for rsync/find wildcards)
    local real_log_bin_basename
    real_log_bin_basename=$(readlink -f "$log_bin_basename")

    local binlog_dir
    binlog_dir=$(dirname "$real_log_bin_basename")
    local binlog_prefix
    binlog_prefix=$(basename "$real_log_bin_basename")

    log "  Detected binlog_dir: $binlog_dir, prefix: $binlog_prefix"

    # To mimic the Postgres staging methodology (where only newly generated logs are moved),
    # we use a marker file to track the last sync time and only copy binlogs modified since then.
    if [ -f "$marker_file" ]; then
        log "  Syncing binlogs modified since last run..."
        find "$binlog_dir" -maxdepth 1 -name "${binlog_prefix}.[0-9]*" -type f -newer "$marker_file" -exec rsync -a {} "${LOG_BACKUP_DIR}/" \;
    else
        log "  First run detected. Syncing all current binlogs..."
        rsync -a "${binlog_dir}/${binlog_prefix}".[0-9]* "${LOG_BACKUP_DIR}/"
    fi
    
    # Update the marker file timestamp for the next run
    touch "$marker_file"
    
    # Sync the index file to ensure it's up to date
    if [ -f "$log_bin_index" ]; then
        rsync -a "$log_bin_index" "${LOG_BACKUP_DIR}/"
    else
        log "WARNING: log_bin_index file not found at $log_bin_index"
    fi
    
    # Purge old binary logs from MySQL so they don't fill up the disk
    local retain_logs=${RETENTION_DAYS_LOG:-3}
    mysql --defaults-extra-file=/root/.my.cnf -e "PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL ${retain_logs} DAY);"
    
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
    log "Running retention cleanup for mode: ${BACKUP_MODE}..."

    # Helper function to delete appropriately named YYYY-MM-DD directories
    delete_old_dirs() {
        local target_dir=$1
        local retention_days=$2
        
        if [ -d "$target_dir" ] && [ -n "$retention_days" ]; then
            local cutoff_date
            # Calculate the cutoff date. Directories named strictly older than this date are deleted.
            cutoff_date=$(date -d "${retention_days} days ago" +"%Y-%m-%d")
            log "  Cleaning up ${target_dir} older than ${cutoff_date} (${retention_days} days retention)"
            
            for dir in "$target_dir"/*; do
                if [ -d "$dir" ]; then
                    local dirname
                    dirname=$(basename "$dir")
                    # Check if dirname matches YYYY-MM-DD pattern precisely
                    if [[ "$dirname" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                        # String comparison for ISO dates to determine age
                        if [[ "$dirname" < "$cutoff_date" ]]; then
                            log "  Deleting ancient backup dir: $dir"
                            rm -rf "$dir"
                        fi
                    fi
                fi
            done
        fi
    }

    if [ "$BACKUP_MODE" == "full" ] || [ "$BACKUP_MODE" == "auto" ]; then
        if [ -n "$RETENTION_DAYS_FULL" ]; then
            delete_old_dirs "${BACKUP_ROOT}/${INSTANCE_NAME}/full" "$RETENTION_DAYS_FULL"
        fi
    fi

    if [ "$BACKUP_MODE" == "log" ] || [ "$BACKUP_MODE" == "auto" ]; then
        if [ -n "$RETENTION_DAYS_LOG" ]; then
            delete_old_dirs "${BACKUP_ROOT}/${INSTANCE_NAME}/logs" "$RETENTION_DAYS_LOG"
        fi
    fi
    
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
