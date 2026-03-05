#!/bin/bash
set -ex

# Install LVM and PostgreSQL
sudo apt install -y lvm2 postgresql postgresql-contrib

# Activate any existing volume groups
sudo vgscan
sudo vgchange -ay

sudo systemctl enable --now postgresql

# Get password from metadata
DB_PASSWORD=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/DB_PASSWORD)

# Set password for postgres user
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${DB_PASSWORD}';"
# Get DB name from metadata
DB_NAME=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/POSTGRES_DB_NAME)

if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw ${DB_NAME}; then
    sudo -u postgres createdb ${DB_NAME}
else
    echo "Database ${DB_NAME} already exists."
fi

# --- LVM Setup for Data Disk ---
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
sudo mkdir -p /var/lib/postgresql_data
if ! mount | grep -q '/var/lib/postgresql_data'; then
    sudo mount -o discard,defaults ${DATA_LV} /var/lib/postgresql_data
fi
if ! grep -q "${DATA_LV}" /etc/fstab; then
    echo ${DATA_LV} /var/lib/postgresql_data ext4 discard,defaults,nofail 0 2 | sudo tee -a /etc/fstab
fi

# Stop PostgreSQL to move data
sudo systemctl stop postgresql

PG_VERSION=$(ls /etc/postgresql/ | head -n 1)

# Check if data is already moved
if [ -L "/var/lib/postgresql/$PG_VERSION/main" ] && [ "$(readlink -f /var/lib/postgresql/$PG_VERSION/main)" == "/var/lib/postgresql_data/main" ]; then
    echo "PostgreSQL data already moved to separate disk. Skipping move."
else
    # Backup current data
    if [ -d "/var/lib/postgresql/$PG_VERSION/main" ]; then
        # Ensure backup dir doesn't prevent move
        sudo rm -rf /var/lib/postgresql/$PG_VERSION/main_backup
        sudo mv /var/lib/postgresql/$PG_VERSION/main /var/lib/postgresql/$PG_VERSION/main_backup
    else
        sudo mkdir -p /var/lib/postgresql/$PG_VERSION/main_backup
    fi

    # Create new directory on the mounted disk
    sudo mkdir -p /var/lib/postgresql_data/main
    sudo rsync -av /var/lib/postgresql/$PG_VERSION/main_backup/ /var/lib/postgresql_data/main/
    sudo chown -R postgres:postgres /var/lib/postgresql_data/main
    sudo rm -rf /var/lib/postgresql/$PG_VERSION/main
    sudo ln -s /var/lib/postgresql_data/main /var/lib/postgresql/$PG_VERSION/main
    sudo chown -R postgres:postgres /var/lib/postgresql/$PG_VERSION/main
fi

sudo systemctl start postgresql

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
sudo mkdir -p /var/lib/postgresql_backups
if ! mount | grep -q '/var/lib/postgresql_backups'; then
    sudo mount -o discard,defaults ${BACKUP_LV} /var/lib/postgresql_backups
fi
if ! grep -q "${BACKUP_LV}" /etc/fstab; then
    echo ${BACKUP_LV} /var/lib/postgresql_backups ext4 discard,defaults,nofail 0 2 | sudo tee -a /etc/fstab
fi
sudo chown -R postgres:postgres /var/lib/postgresql_backups

echo "PostgreSQL setup complete."

# --- Configure Backups ---
echo "Configuring backups..."

# 1. Fetch config
RETENTION_DAYS=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_RETENTION_DAYS)
FULL_INTERVAL=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/FULL_BACKUP_INTERVAL_HOURS)
LOG_INTERVAL=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/LOG_BACKUP_INTERVAL_MINUTES)
BACKUP_SCRIPT_CONTENT=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_SCRIPT_CONTENT)

# 2. Install backup script
echo "${BACKUP_SCRIPT_CONTENT}" | sudo tee /usr/local/bin/db_backup.sh > /dev/null
sudo chmod +x /usr/local/bin/db_backup.sh

# 3. Configure WAL Archiving
# Re-detect version to be safe
PG_VERSION=$(ls /etc/postgresql/ | head -n 1)
PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
INSTANCE_NAME=$(hostname)
# Old: /var/lib/postgresql/archive_staging
# New: /var/lib/postgresql_backups/${INSTANCE_NAME}/wal_staging
# We still symlink from a standard location for postgres trigger simplicity or just update conf directly
# Let's keep the symlink approach but point to new location

ARCHIVE_DIR="/var/lib/postgresql/archive_staging"
# We can keep the local symlink name simple if we want, or make it verifyable.
# User dislikes "archive_staging". Let's name the symlink "wal_staging" too?
# Or just point directly.
# Let's point directly to avoid confusion if possible, or update symlink.
# "the folder name should be the name of the database instance name" -> /var/lib/postgresql_backups/$INSTANCE_NAME
REAL_BACKUP_ROOT="/var/lib/postgresql_backups/${INSTANCE_NAME}"
REAL_ARCHIVE_DIR="${REAL_BACKUP_ROOT}/wal_staging"

# Create staging on backup disk and symlink
sudo mkdir -p "${REAL_ARCHIVE_DIR}"
sudo chown -R postgres:postgres "${REAL_BACKUP_ROOT}"
if [ ! -L "${ARCHIVE_DIR}" ]; then
    sudo ln -s "${REAL_ARCHIVE_DIR}" "${ARCHIVE_DIR}"
fi
sudo chown -h postgres:postgres "${ARCHIVE_DIR}"

# Update postgresql.conf
if ! grep -q "^archive_mode = on" "${PG_CONF}"; then
    sudo sed -i "s/#*archive_mode = .*/archive_mode = on/" "${PG_CONF}"
    sudo sed -i "s/#*wal_level = .*/wal_level = replica/" "${PG_CONF}"
    
    # Archive command: copy to staging
    CMD="test ! -f ${ARCHIVE_DIR}/%f && cp %p ${ARCHIVE_DIR}/%f"
    sudo sed -i "s|#*archive_command = .*|archive_command = '${CMD}'|" "${PG_CONF}"
    
    sudo systemctl restart postgresql
fi

# 4. Cron
CRON_SCHEDULE="*/${LOG_INTERVAL} * * * *"
if [ "${LOG_INTERVAL}" -ge 60 ]; then
   CRON_SCHEDULE="0 * * * *"
fi

# Write cron job
echo "${CRON_SCHEDULE} root DB_TYPE=postgres BACKUP_DIR=/var/lib/postgresql_backups INSTANCE_NAME=$(hostname) RETENTION_DAYS=${RETENTION_DAYS} FULL_BACKUP_INTERVAL_HOURS=${FULL_INTERVAL} /usr/local/bin/db_backup.sh >> /var/log/db_backup.log 2>&1" | sudo tee /etc/cron.d/db_backup

echo "Backup configuration complete."
