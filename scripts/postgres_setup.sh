#!/bin/bash
set -ex

# Install LVM and PostgreSQL
sudo apt install -y lvm2 postgresql postgresql-contrib

sudo systemctl enable --now postgresql

# Set password for postgres user
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'YourSecurePassword1!';"
if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw db1; then
    sudo -u postgres createdb db1
else
    echo "Database db1 already exists."
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
    echo ${DATA_LV} /var/lib/postgresql_data ext4 discard,defaults,NOFAIL_OPTION 0 2 | sudo tee -a /etc/fstab
fi

# Stop PostgreSQL to move data
sudo systemctl stop postgresql

PG_VERSION=$(ls /etc/postgresql/)
# Backup current data
if [ -d "/var/lib/postgresql/$PG_VERSION/main" ]; then
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
sudo chown -R postgres:postgres /var/lib/postgresql/$PG_VERSION/main # Apply ownership to the symlink itself

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
    echo ${BACKUP_LV} /var/lib/postgresql_backups ext4 discard,defaults,NOFAIL_OPTION 0 2 | sudo tee -a /etc/fstab
fi
sudo chown -R postgres:postgres /var/lib/postgresql_backups

echo "PostgreSQL setup complete."
