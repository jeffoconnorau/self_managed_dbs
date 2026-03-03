#!/bin/bash
set -ex

# Check if MySQL service is already running
if systemctl is-active --quiet mysqld; then
    echo "MySQL service is already running. Skipping setup."
else
    echo "MySQL service not running. Proceeding with setup..."

    # 1. Install LVM2
    if ! rpm -q lvm2 > /dev/null 2>&1; then
        sudo dnf install -y lvm2
    fi

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
        echo ${DATA_LV} ${MYSQL_DATA_DIR} ext4 discard,defaults,NOFAIL_OPTION 0 2 | sudo tee -a /etc/fstab
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
        echo ${BACKUP_LV} /var/lib/mysql_backups ext4 discard,defaults,NOFAIL_OPTION 0 2 | sudo tee -a /etc/fstab
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
    echo "Running basic MySQL security steps..."

    NEW_PASSWORD="MyS@L_1nSt@nce!P@$$wOrd0"

    # Basic security steps with the new password
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='';"
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "DROP DATABASE IF EXISTS test;"
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';"
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "FLUSH PRIVILEGES;"
    # Create db1
    sudo mysql -u root -p"${NEW_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS db1;"

    # Update verify_db.sh script with the new password
    # This assumes verify_db.sh is in the same directory as mysql_setup.sh on the VM
    if [ -f "verify_db.sh" ]; then
        sed -i "s/MYSQL_PWD='.*'/MYSQL_PWD='${NEW_PASSWORD}'/" verify_db.sh
    fi

    # Set ownership for backup directory
    sudo chown -R mysql:mysql /var/lib/mysql_backups

    echo "MySQL setup complete."
fi

echo "Startup script finished."
