#!/bin/bash
echo "DEBUG: mysql_setup.sh starting"
set -ex
echo "DEBUG: set -ex done"

# Check if MySQL service is already running
if systemctl is-active --quiet mysqld; then
    echo "MySQL service is already running. Skipping setup."
else
    echo "MySQL service not running. Proceeding with setup..."

    # 1. Install LVM2
    if ! rpm -q lvm2 > /dev/null 2>&1; then
        sudo dnf install -y lvm2
    fi
    # Activate any existing volume groups/logical volumes
    sudo vgscan
    sudo vgchange -ay

    # 2. --- LVM Setup for Data Disk ---
    DATA_DISK=/dev/sdb
    if ! sudo pvs ${DATA_DISK} > /dev/null 2>&1; then
        sudo pvcreate ${DATA_DISK}
    fi
    if ! sudo vgs data_vg > /dev/null 2>&1; then
        sudo vgcreate data_vg ${DATA_DISK}
    fi
    if ! sudo lvs /dev/data_vg/data_lv > /dev/null 2>&1; then
        sudo lvcreate -l 100%FREE -n data_lv data_vg
    fi
    DATA_LV=/dev/data_vg/data_lv
    if ! blkid ${DATA_LV} | grep -q 'TYPE="ext4"'; then
        sudo mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard ${DATA_LV}
    fi
    MYSQL_DATA_DIR=/var/lib/mysql_data
    sudo mkdir -p ${MYSQL_DATA_DIR}
    if ! mount | grep -q "${MYSQL_DATA_DIR}"; then
        sudo mount -o discard,defaults ${DATA_LV} ${MYSQL_DATA_DIR}
    fi
    if ! grep -q "${DATA_LV}" /etc/fstab; then
        echo ${DATA_LV} ${MYSQL_DATA_DIR} ext4 discard,defaults,nofail 0 2 | sudo tee -a /etc/fstab
    fi

    # --- LVM Setup for Backup Disk ---
    BACKUP_DISK=/dev/sdc
    if ! sudo pvs ${BACKUP_DISK} > /dev/null 2>&1; then
        sudo pvcreate ${BACKUP_DISK}
    fi
    if ! sudo vgs backup_vg > /dev/null 2>&1; then
        sudo vgcreate backup_vg ${BACKUP_DISK}
    fi
    if ! sudo lvs /dev/backup_vg/backup_lv > /dev/null 2>&1; then
        sudo lvcreate -l 100%FREE -n backup_lv backup_vg
    fi
    BACKUP_LV=/dev/backup_vg/backup_lv
    if ! blkid ${BACKUP_LV} | grep -q 'TYPE="ext4"'; then
        sudo mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard ${BACKUP_LV}
    fi
    sudo mkdir -p /var/lib/mysql_backups
    if ! mount | grep -q '/var/lib/mysql_backups'; then
        sudo mount -o discard,defaults ${BACKUP_LV} /var/lib/mysql_backups
    fi
    if ! grep -q "${BACKUP_LV}" /etc/fstab; then
        echo ${BACKUP_LV} /var/lib/mysql_backups ext4 discard,defaults,nofail 0 2 | sudo tee -a /etc/fstab
    fi

    # 3. Install SELinux management tools
    if ! rpm -q policycoreutils-python-utils > /dev/null 2>&1; then
        sudo dnf install -y policycoreutils-python-utils
    fi

    # 4. Download MySQL Community Repository RPM
    REPO_RPM_URL="https://dev.mysql.com/get/mysql80-community-release-el9-1.noarch.rpm"
    REPO_RPM_LOCAL="/tmp/mysql80-community-release-el9-1.noarch.rpm"
    if ! dnf repolist | grep -q "mysql.com"; then
      sudo curl -L -o ${REPO_RPM_LOCAL} ${REPO_RPM_URL}
    fi

    # 4. Install the downloaded Repository RPM
    if [ -f "${REPO_RPM_LOCAL}" ]; then
        sudo dnf install -y --nogpgcheck ${REPO_RPM_LOCAL}
        sudo rm -f ${REPO_RPM_LOCAL}
    fi
    sudo dnf clean all
    sudo dnf repolist all

    # 5. Install MySQL Server
    sudo rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2022
    sudo dnf install -y -v --nogpgcheck --disableplugin=fastestmirror mysql-community-server

    # 6. Install rsync
    if ! rpm -q rsync > /dev/null 2>&1; then
        sudo dnf install -y rsync
    fi

    # 7. Configure MySQL Data Directory & Basic Security
    # Stop MySQL to move data
    if systemctl is-active --quiet mysqld; then
        sudo systemctl stop mysqld
    fi

    # Backup current data if it exists and is not a symlink
    if [ -d "/var/lib/mysql" ] && [ ! -L "/var/lib/mysql" ]; then
        sudo mv /var/lib/mysql /var/lib/mysql_backup
    else
        sudo mkdir -p /var/lib/mysql_backup
    fi

    # Ensure target directory on LVM exists
    sudo mkdir -p ${MYSQL_DATA_DIR}/mysql
    # Copy data if any exists in backup
    sudo rsync -av --ignore-existing /var/lib/mysql_backup/ ${MYSQL_DATA_DIR}/mysql/
    sudo chown -R mysql:mysql ${MYSQL_DATA_DIR}/mysql
    sudo rm -rf /var/lib/mysql_backup

    # Remove old datadir and create symlink
    if [ -d "/var/lib/mysql" ] && [ ! -L "/var/lib/mysql" ]; then
      sudo rm -rf /var/lib/mysql
    fi
    if [ ! -L "/var/lib/mysql" ]; then
      sudo ln -s ${MYSQL_DATA_DIR}/mysql /var/lib/mysql
    fi
    sudo chown -h mysql:mysql /var/lib/mysql # Apply ownership to the symlink itself

    # Update my.cnf to point to the new datadir
    sudo sed -i 's|^datadir=.*|datadir=/var/lib/mysql|' /etc/my.cnf
    sudo sed -i 's|^socket=.*|socket=/var/lib/mysql/mysql.sock|' /etc/my.cnf

    # SELinux context for custom data directory
    sudo semanage fcontext -a -t mysqld_db_t "${MYSQL_DATA_DIR}/mysql(/.*)?"
    sudo restorecon -R -v ${MYSQL_DATA_DIR}/mysql

    sudo systemctl enable --now mysqld

    # --- Secure MySQL Installation ---
    echo "Setting root password and securing MySQL..."

    NEW_PASSWORD=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/DB_PASSWORD)

    # Stop service to restart with skip-grant-tables
    if systemctl is-active --quiet mysqld; then
        sudo systemctl stop mysqld
    fi

    echo "Starting mysqld with --skip-grant-tables..."
    # Start mysqld directly with skip-grant-tables
    sudo mysqld --user=mysql --daemonize --skip-grant-tables --skip-networking
    
    # Wait for it to start
    for i in {1..30}; do
        if sudo mysql -u root -e "SELECT 1" > /dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    echo "Updating root password..."
    # FLUSH PRIVILEGES is needed to reload grant tables so we can use ALTER USER
    sudo mysql -u root <<EOF
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${NEW_PASSWORD}';
FLUSH PRIVILEGES;
EOF

    echo "Restarting mysqld normally..."
    # Find the pid of the manual mysqld process and kill it
    sudo pkill mysqld
    # Wait for it to stop
    while pgrep mysqld > /dev/null; do sleep 1; done

    sudo systemctl start mysqld

    echo "Root password set. Running additional security steps..."

    # Basic security steps with the new password
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='';" || true
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" || true
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "DROP DATABASE IF EXISTS test;" || true
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';" || true
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "FLUSH PRIVILEGES;" || true

    # Get DB name from metadata
    DB_NAME=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/MYSQL_DB_NAME)

    # Create database
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"

    # Update verify_db.sh script with the new password (if it exists on the VM)
    if [ -f "verify_db.sh" ]; then
        sed -i "s/MYSQL_PWD='.*'/MYSQL_PWD='${NEW_PASSWORD}'/" verify_db.sh
    fi

    # Set ownership for backup directory
    sudo chown -R mysql:mysql /var/lib/mysql_backups

    # Create .my.cnf for backup script
    echo "[client]" | sudo tee /root/.my.cnf > /dev/null
    echo "user=root" | sudo tee -a /root/.my.cnf > /dev/null
    echo "password=${NEW_PASSWORD}" | sudo tee -a /root/.my.cnf > /dev/null
    sudo chmod 600 /root/.my.cnf

    echo "MySQL setup complete."
fi

# --- Configure Backups ---
echo "Configuring backups..."

# 1. Fetch backup config
echo "Fetching backup configuration from metadata..."
RETENTION_DAYS=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_RETENTION_DAYS || echo "3")
RETENTION_DAYS_FULL=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_RETENTION_DAYS_FULL || echo "${RETENTION_DAYS}")
RETENTION_DAYS_LOG=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_RETENTION_DAYS_LOG || echo "${RETENTION_DAYS}")
FULL_INTERVAL=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/FULL_BACKUP_INTERVAL_HOURS || echo "24")
LOG_INTERVAL=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/LOG_BACKUP_INTERVAL_MINUTES || echo "15")
BACKUP_SCRIPT_CONTENT=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_SCRIPT_CONTENT)

echo "Configuration fetched: FULL=${RETENTION_DAYS_FULL}, LOG=${RETENTION_DAYS_LOG}"

# 2. Install backup script
echo "${BACKUP_SCRIPT_CONTENT}" | sudo tee /usr/local/bin/db_backup.sh > /dev/null
sudo chmod +x /usr/local/bin/db_backup.sh

# 3. Configure MySQL Binlogs (if not already explicit)
# MySQL 8 enables binlog by default, but we ensure settings.
if ! grep -q "log_bin" /etc/my.cnf; then
    sudo sed -i '/\[mysqld\]/a log_bin = /var/lib/mysql/mysql-bin' /etc/my.cnf
    sudo sed -i '/\[mysqld\]/a server_id = 1' /etc/my.cnf
    sudo sed -i '/\[mysqld\]/a binlog_expire_logs_seconds = 604800' /etc/my.cnf
    sudo systemctl restart mysqld
fi

# 4. Setup Cron
# Default to */15 if not set or weird
CRON_SCHEDULE="*/${LOG_INTERVAL} * * * *"
if [ "${LOG_INTERVAL}" -ge 60 ]; then
   CRON_SCHEDULE="0 * * * *"
fi

# Write cron jobs
# 1. Log Backups (Every 15 mins by default)
echo "${CRON_SCHEDULE} root DB_TYPE=mysql BACKUP_MODE=log BACKUP_DIR=/var/lib/mysql_backups INSTANCE_NAME=$(hostname) RETENTION_DAYS_LOG=${RETENTION_DAYS_LOG} /usr/local/bin/db_backup.sh >> /var/log/db_backup_log.log 2>&1" | sudo tee /etc/cron.d/db_backup

# 2. Full Backups (Daily at specified time, default 02:00)
FULL_BACKUP_TIME=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/FULL_BACKUP_TIME || echo "02:00")

# If FULL_BACKUP_TIME is set (it should be, via default), configure it
if [ -n "$FULL_BACKUP_TIME" ]; then
    echo "Configuring full backup schedule: ${FULL_BACKUP_TIME}"
    IFS=':' read -r HH MM <<< "${FULL_BACKUP_TIME}"
    # Verify we got numbers
    if [[ "$HH" =~ ^[0-9]+$ ]] && [[ "$MM" =~ ^[0-9]+$ ]]; then
        echo "${MM} ${HH} * * * root DB_TYPE=mysql BACKUP_MODE=full BACKUP_DIR=/var/lib/mysql_backups INSTANCE_NAME=$(hostname) RETENTION_DAYS_FULL=${RETENTION_DAYS_FULL} /usr/local/bin/db_backup.sh >> /var/log/db_backup_full.log 2>&1" | sudo tee -a /etc/cron.d/db_backup
    else
        echo "WARNING: Invalid FULL_BACKUP_TIME format: ${FULL_BACKUP_TIME}. Expected HH:MM."
    fi
else
    # Fallback to auto/interval based if no time is set (legacy behavior safety net)
    echo "WARNING: No FULL_BACKUP_TIME set. Configuring legacy auto-backup check every hour."
    echo "0 * * * * root DB_TYPE=mysql BACKUP_MODE=auto BACKUP_DIR=/var/lib/mysql_backups INSTANCE_NAME=$(hostname) RETENTION_DAYS_FULL=${RETENTION_DAYS_FULL} RETENTION_DAYS_LOG=${RETENTION_DAYS_LOG} FULL_BACKUP_INTERVAL_HOURS=${FULL_INTERVAL} /usr/local/bin/db_backup.sh >> /var/log/db_backup_auto.log 2>&1" | sudo tee -a /etc/cron.d/db_backup
fi

echo "Backup configuration complete."

echo "Startup script finished."
