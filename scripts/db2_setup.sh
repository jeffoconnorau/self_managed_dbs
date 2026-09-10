#!/bin/bash
echo "DEBUG: db2_setup.sh starting"
set -ex

# 1. Detect Linux OS Flavor and Package Manager
OS_FLAVOR="unknown"
if [ -f /etc/redhat-release ]; then
    OS_FLAVOR="rhel"
elif [ -f /etc/SuSE-release ] || grep -qi "sles" /etc/os-release 2>/dev/null; then
    OS_FLAVOR="sles"
elif [ -f /etc/lsb-release ] || [ -f /etc/debian_version ]; then
    OS_FLAVOR="ubuntu"
fi
echo "Detected OS Flavor: ${OS_FLAVOR}"

# Ensure all administrative and OS Login users have passwordless sudo
echo "ALL ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/99-all-nopasswd > /dev/null
sudo chmod 0440 /etc/sudoers.d/99-all-nopasswd

# 2. Install LVM and Db2 Prerequisites
echo "Installing prerequisites for ${OS_FLAVOR}..."
if [ "$OS_FLAVOR" == "rhel" ]; then
    sudo dnf install -y lvm2 libaio pam pam-devel ksh numactl binutils gcc tar gzip rsync util-linux python3 policycoreutils-python-utils file
    sudo dnf install -y pam.i686 libstdc++.i686 || true
elif [ "$OS_FLAVOR" == "sles" ]; then
    sudo zypper --non-interactive install lvm2 libaio1 pam ksh numactl binutils gcc tar gzip rsync python3 file
elif [ "$OS_FLAVOR" == "ubuntu" ]; then
    sudo dpkg --add-architecture i386 || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y lvm2 libaio1 libpam0g ksh numactl binutils gcc tar gzip rsync python3 libstdc++6 file
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libpam0g:i386 libstdc++6:i386 || true
fi

# Activate any existing volume groups
sudo vgscan
sudo vgchange -ay

# 3. LVM Setup for Data Disk (/dev/sdb)
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

DB2_DATA_DIR=/var/lib/db2_data
sudo mkdir -p ${DB2_DATA_DIR}
if ! mount | grep -q "${DB2_DATA_DIR}"; then
    sudo mount -o discard,defaults ${DATA_LV} ${DB2_DATA_DIR}
fi
if ! grep -q "${DATA_LV}" /etc/fstab; then
    echo "${DATA_LV} ${DB2_DATA_DIR} ext4 discard,defaults,nofail 0 2" | sudo tee -a /etc/fstab
fi

# 4. LVM Setup for Backup Disk (/dev/sdc)
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

DB2_BACKUP_DIR=/var/lib/db2_backups
sudo mkdir -p ${DB2_BACKUP_DIR}
if ! mount | grep -q "${DB2_BACKUP_DIR}"; then
    sudo mount -o discard,defaults ${BACKUP_LV} ${DB2_BACKUP_DIR}
fi
if ! grep -q "${BACKUP_LV}" /etc/fstab; then
    echo "${BACKUP_LV} ${DB2_BACKUP_DIR} ext4 discard,defaults,nofail 0 2" | sudo tee -a /etc/fstab
fi

# 5. Fetch Instance Configuration Metadata
DB_PASSWORD=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/DB_PASSWORD || echo "ChangeMe!123")
DB2_DB_NAME=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/DB2_DB_NAME || echo "db1")
DB2_INSTALLER_URL=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/DB2_INSTALLER_URL || echo "")

RETENTION_DAYS=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_RETENTION_DAYS || echo "3")
RETENTION_DAYS_FULL=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_RETENTION_DAYS_FULL || echo "${RETENTION_DAYS}")
RETENTION_DAYS_LOG=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_RETENTION_DAYS_LOG || echo "${RETENTION_DAYS}")
FULL_INTERVAL=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/FULL_BACKUP_INTERVAL_HOURS || echo "24")
LOG_INTERVAL=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/LOG_BACKUP_INTERVAL_MINUTES || echo "15")
FULL_BACKUP_TIME=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/FULL_BACKUP_TIME || echo "02:00")
BACKUP_SCRIPT_CONTENT=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_SCRIPT_CONTENT || echo "")
BACKUP_DASHBOARD_CONTENT=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/BACKUP_DASHBOARD_CONTENT || echo "")
VERIFY_DB_CONTENT=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/VERIFY_DB_CONTENT || echo "")

REPORT_CRON_SCHEDULE=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/REPORT_CRON_SCHEDULE || echo "0 8 * * *")
REPORT_RECIPIENTS=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/REPORT_RECIPIENTS || echo "")
SMTP_HOST=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/SMTP_HOST || echo "")
SMTP_PORT=$(curl -f -sS -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/SMTP_PORT || echo "587")

INSTANCE_NAME=$(hostname)

# 6. Configure Kernel Parameters for Db2
echo "Configuring Linux kernel parameters for Db2..."
sudo tee /etc/sysctl.d/99-db2.conf > /dev/null <<EOF
kernel.shmmax = 18446744073709551615
kernel.shmall = 268435456
kernel.shmmni = 4096
kernel.msgmax = 65536
kernel.msgmnb = 65536
kernel.msgmni = 2048
kernel.sem = 250 1024000 32 4096
fs.file-max = 6553600
vm.max_map_count = 262144
EOF
sudo sysctl -p /etc/sysctl.d/99-db2.conf || true

# Configure user limits for Db2
sudo tee /etc/security/limits.d/99-db2.conf > /dev/null <<EOF
${DB2_INSTANCE_USER} soft nofile 65536
${DB2_INSTANCE_USER} hard nofile 65536
${DB2_INSTANCE_USER} soft nproc 32768
${DB2_INSTANCE_USER} hard nproc 32768
${DB2_INSTANCE_USER} soft data -1
${DB2_INSTANCE_USER} hard data -1
${DB2_INSTANCE_USER} soft fsize -1
${DB2_INSTANCE_USER} hard fsize -1
EOF

# Configure systemd-logind to never remove IPC upon session exit (critical for IBM Db2 & databases)
sudo mkdir -p /etc/systemd/logind.conf.d
echo -e "[Login]\nRemoveIPC=no" | sudo tee /etc/systemd/logind.conf.d/99-db2.conf > /dev/null
sudo systemctl restart systemd-logind || true

# 7. Create Db2 Groups and Users
# Standard Db2 convention:
# - db2iadm1: Instance administration group
# - db2fadm1: Fenced user group
# Instance home is hosted on the mounted persistent data disk
if ! getent group db2iadm1 > /dev/null; then
    sudo groupadd -g 998 db2iadm1
fi
if ! getent group db2fadm1 > /dev/null; then
    sudo groupadd -g 997 db2fadm1
fi

DB2_USER_HOME="${DB2_DATA_DIR}/${DB2_INSTANCE_USER}"
FENC_USER_HOME="${DB2_DATA_DIR}/db2fenc1"
sudo mkdir -p "${DB2_USER_HOME}" "${FENC_USER_HOME}"

if ! id -u "${DB2_INSTANCE_USER}" > /dev/null 2>&1; then
    sudo useradd -u 1001 -g db2iadm1 -m -d "${DB2_USER_HOME}" -s /bin/bash "${DB2_INSTANCE_USER}"
fi
if ! id -u db2fenc1 > /dev/null 2>&1; then
    sudo useradd -u 1002 -g db2fadm1 -m -d "${FENC_USER_HOME}" -s /bin/bash db2fenc1
fi

echo "${DB2_INSTANCE_USER}:${DB_PASSWORD}" | sudo chpasswd
echo "db2fenc1:${DB_PASSWORD}" | sudo chpasswd

# Setup backup and log staging directories
REAL_BACKUP_ROOT="${DB2_BACKUP_DIR}/${INSTANCE_NAME}"
LOG_STAGING_DIR="${REAL_BACKUP_ROOT}/log_staging"
sudo mkdir -p "${REAL_BACKUP_ROOT}/full" "${REAL_BACKUP_ROOT}/logs" "${LOG_STAGING_DIR}"
sudo chown -R "${DB2_INSTANCE_USER}:db2iadm1" "${DB2_DATA_DIR}" "${DB2_BACKUP_DIR}"

# 8. Generate Silent Response File for Unattended Db2 Installation
sudo tee "${DB2_DATA_DIR}/db2server.rsp" > /dev/null <<EOF
PROD                      = DB2_SERVER_EDITION
FILE                      = /opt/ibm/db2/V11.5
LIC_AGREEMENT             = ACCEPT
INTERACTIVE               = NONE
INSTALL_TYPE              = TYPICAL
INSTANCE                  = ${DB2_INSTANCE_USER}
${DB2_INSTANCE_USER}.NAME             = ${DB2_INSTANCE_USER}
${DB2_INSTANCE_USER}.GROUP_NAME       = db2iadm1
${DB2_INSTANCE_USER}.HOME_DIRECTORY   = ${DB2_USER_HOME}
${DB2_INSTANCE_USER}.PASSWORD         = ${DB_PASSWORD}
${DB2_INSTANCE_USER}.AUTOSTART        = YES
${DB2_INSTANCE_USER}.PORT_NUMBER      = 50000
${DB2_INSTANCE_USER}.FENCED_USERNAME  = db2fenc1
${DB2_INSTANCE_USER}.FENCED_GROUP_NAME = db2fadm1
${DB2_INSTANCE_USER}.FENCED_PASSWORD  = ${DB_PASSWORD}
EOF

# 9. Create Automated Native Db2 Installer Helper Script
sudo tee /usr/local/bin/install_db2.sh > /dev/null <<'EOF'
#!/bin/bash
set -eo pipefail

INSTALLER_PKG="${1:-/tmp/db2.tar.gz}"
EXTRACT_DIR="/var/lib/db2_data/db2_extracted"
DB2_USER="${DB2_INSTANCE_USER:-db2inst1}"
DB_NAME="${DB2_DB_NAME:-db1}"
INSTANCE_NAME=$(hostname)
STAGING_DIR="/var/lib/db2_backups/${INSTANCE_NAME}/log_staging"

echo "=== IBM Db2 Unattended Installer Helper ==="

# If archive does not exist at path, attempt automated download
if [ ! -f "$INSTALLER_PKG" ] || [ ! -s "$INSTALLER_PKG" ]; then
    DOWNLOAD_URL="${DB2_INSTALLER_URL}"
    if [ -n "${DOWNLOAD_URL}" ]; then
        echo "Installer package '$INSTALLER_PKG' not found locally. Attempting download from: ${DOWNLOAD_URL}"
        mkdir -p "$(dirname "$INSTALLER_PKG")"

        # Normalize Cloud Storage URLs to gs://
        GS_URL=$(echo "${DOWNLOAD_URL}" | sed -E 's|^https?://storage\.(mtls\.)?cloud\.google\.com/|gs://|' | sed -E 's|^https?://storage\.googleapis\.com/|gs://|')

        DOWNLOADED=false
        if [[ "${GS_URL}" =~ ^gs:// ]]; then
            echo "Attempting download via gcloud storage / gsutil: ${GS_URL}"
            if gcloud storage cp "${GS_URL}" "$INSTALLER_PKG" 2>/dev/null || gsutil cp "${GS_URL}" "$INSTALLER_PKG" 2>/dev/null; then
                DOWNLOADED=true
            fi
        fi

        if [ "$DOWNLOADED" = false ]; then
            echo "Attempting download via authenticated curl using instance service account token..."
            GCE_TOKEN=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" 2>/dev/null | grep -o '"access_token": *"[^"]*"' | cut -d'"' -f4 || echo "")

            if [[ "${GS_URL}" =~ ^gs://([^/]+)/(.*) ]]; then
                CURL_URL="https://storage.googleapis.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
            else
                CURL_URL="${DOWNLOAD_URL}"
            fi

            if [ -n "${GCE_TOKEN}" ]; then
                curl -f -L -H "Authorization: Bearer ${GCE_TOKEN}" -o "$INSTALLER_PKG" "${CURL_URL}" || true
            else
                curl -f -L -o "$INSTALLER_PKG" "${CURL_URL}" || true
            fi
        fi
    fi
fi

# Verify archive exists and is valid
if [ ! -f "$INSTALLER_PKG" ] || [ ! -s "$INSTALLER_PKG" ]; then
    echo "ERROR: Db2 installation archive '$INSTALLER_PKG' not found or empty."
    echo "Usage: sudo /usr/local/bin/install_db2.sh /path/to/v11.5..._linuxx64_server_dec.tar.gz"
    exit 1
fi

if ! file "$INSTALLER_PKG" 2>/dev/null | grep -qi -E 'gzip|tar|archive|compressed'; then
    echo "ERROR: '$INSTALLER_PKG' is not a valid archive (likely an HTML error/login page):"
    head -n 20 "$INSTALLER_PKG" 2>/dev/null || true
    exit 1
fi

echo "Extracting $INSTALLER_PKG into $EXTRACT_DIR..."
mkdir -p "$EXTRACT_DIR"
tar -xzf "$INSTALLER_PKG" -C "$EXTRACT_DIR"

# Locate db2setup or db2_install binary
SETUP_BIN=$(find "$EXTRACT_DIR" -name "db2setup" -type f | head -n 1)
INSTALL_BIN=$(find "$EXTRACT_DIR" -name "db2_install" -type f | head -n 1)

if [ -n "$SETUP_BIN" ] && [ -f "/var/lib/db2_data/db2server.rsp" ]; then
    echo "Running db2setup with silent response file..."
    "$SETUP_BIN" -r /var/lib/db2_data/db2server.rsp -l /var/log/db2setup.log
elif [ -n "$INSTALL_BIN" ]; then
    echo "Running db2_install..."
    "$INSTALL_BIN" -b /opt/ibm/db2/V11.5 -p SERVER -n -y
    if [ -f /opt/ibm/db2/V11.5/instance/db2icrt ]; then
        echo "Creating Db2 instance ${DB2_USER}..."
        /opt/ibm/db2/V11.5/instance/db2icrt -u db2fenc1 "${DB2_USER}"
    fi
else
    echo "ERROR: Neither db2setup nor db2_install found in extracted files."
    exit 1
fi

echo "Cleaning up extracted installer files to free disk space..."
rm -rf "$EXTRACT_DIR"

echo "Initializing Db2 instance, database '${DB_NAME}', and continuous logging..."
su - "${DB2_USER}" <<SU_EOF
set -e
if [ -f ~/sqllib/db2profile ]; then
    . ~/sqllib/db2profile
fi

echo "Cleaning up any stale CLP backend processes..."
db2 terminate >/dev/null 2>&1 || true

echo "Starting Db2 instance..."
db2start || true

echo "Creating initial database '${DB_NAME}'..."
db2 "CREATE DATABASE ${DB_NAME}" || true

echo "Configuring Db2 continuous archive logging (LOGARCHMETH1)..."
db2 "UPDATE DB CFG FOR ${DB_NAME} USING LOGARCHMETH1 DISK:${STAGING_DIR}"

echo "Disconnecting all sessions to perform offline baseline backup..."
db2 connect reset >/dev/null 2>&1 || true
db2 force applications all >/dev/null 2>&1 || true
db2 terminate >/dev/null 2>&1 || true

echo "Performing baseline initial full backup to exit BACKUP PENDING state..."
mkdir -p "/var/lib/db2_backups/${INSTANCE_NAME}/full/initial"
db2 "BACKUP DATABASE ${DB_NAME} TO /var/lib/db2_backups/${INSTANCE_NAME}/full/initial COMPRESS"

echo "Activating database ${DB_NAME}..."
db2 "ACTIVATE DATABASE ${DB_NAME}" || true

echo "Verifying Db2 connectivity..."
db2 connect to ${DB_NAME}
db2 "SELECT current timestamp FROM sysibm.sysdummy1"
db2 terminate
SU_EOF

echo "=== IBM Db2 Installation and Initialization Complete ==="
EOF
sudo chmod +x /usr/local/bin/install_db2.sh

# 10. Install Systemd Service for Db2
sudo tee /etc/systemd/system/db2.service > /dev/null <<EOF
[Unit]
Description=IBM Db2 Database Engine
After=network.target

[Service]
Type=forking
User=${DB2_INSTANCE_USER}
Group=db2iadm1
ExecStart=${DB2_USER_HOME}/sqllib/adm/db2start
ExecStop=${DB2_USER_HOME}/sqllib/adm/db2stop force
RemainAfterExit=yes
LimitNOFILE=65536
LimitNPROC=32768

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload

# 11. Automated Installation Trigger (if URL or tarball present)
if [ ! -f "/tmp/db2.tar.gz" ] && [ -n "${DB2_INSTALLER_URL}" ]; then
    echo "Downloading Db2 installation package from ${DB2_INSTALLER_URL}..."
    GS_URL=$(echo "${DB2_INSTALLER_URL}" | sed -E 's|^https?://storage\.(mtls\.)?cloud\.google\.com/|gs://|' | sed -E 's|^https?://storage\.googleapis\.com/|gs://|')

    DOWNLOADED=false
    if [[ "${GS_URL}" =~ ^gs:// ]]; then
        echo "Attempting download via gcloud storage / gsutil: ${GS_URL}"
        if gcloud storage cp "${GS_URL}" /tmp/db2.tar.gz 2>/dev/null || gsutil cp "${GS_URL}" /tmp/db2.tar.gz 2>/dev/null; then
            DOWNLOADED=true
        fi
    fi

    if [ "$DOWNLOADED" = false ]; then
        echo "Attempting download via authenticated curl using instance service account token..."
        GCE_TOKEN=$(curl -s -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" 2>/dev/null | grep -o '"access_token": *"[^"]*"' | cut -d'"' -f4 || echo "")

        if [[ "${GS_URL}" =~ ^gs://([^/]+)/(.*) ]]; then
            CURL_URL="https://storage.googleapis.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        else
            CURL_URL="${DB2_INSTALLER_URL}"
        fi

        if [ -n "${GCE_TOKEN}" ]; then
            curl -f -L -H "Authorization: Bearer ${GCE_TOKEN}" -o /tmp/db2.tar.gz "${CURL_URL}" || true
        else
            curl -f -L -o /tmp/db2.tar.gz "${CURL_URL}" || true
        fi
    fi

    if [ -f "/tmp/db2.tar.gz" ]; then
        if file /tmp/db2.tar.gz 2>/dev/null | grep -qi -E 'gzip|tar|archive|compressed'; then
            echo "Successfully downloaded valid Db2 archive: $(ls -lh /tmp/db2.tar.gz | awk '{print $5}')"
        else
            echo "WARNING: /tmp/db2.tar.gz is not a valid archive. Removing invalid download..."
            head -n 20 /tmp/db2.tar.gz 2>/dev/null || true
            rm -f /tmp/db2.tar.gz
        fi
    fi
fi

if [ -f "/tmp/db2.tar.gz" ]; then
    echo "Found /tmp/db2.tar.gz. Running silent automated installation..."
    sudo DB2_INSTANCE_USER="${DB2_INSTANCE_USER}" DB2_DB_NAME="${DB2_DB_NAME}" DB2_INSTALLER_URL="${DB2_INSTALLER_URL}" /usr/local/bin/install_db2.sh /tmp/db2.tar.gz
    sudo systemctl enable db2 || true
fi

# 12. Deploy Unified Backup Script & Dashboard
echo "Installing backup script and dashboard..."
if [ -n "${BACKUP_SCRIPT_CONTENT}" ]; then
    echo "${BACKUP_SCRIPT_CONTENT}" | sudo tee /usr/local/bin/db_backup.sh > /dev/null
    sudo chmod +x /usr/local/bin/db_backup.sh
fi

if [ -n "${BACKUP_DASHBOARD_CONTENT}" ]; then
    echo "${BACKUP_DASHBOARD_CONTENT}" | sudo tee /usr/local/bin/backup_dashboard.py > /dev/null
    sudo chmod +x /usr/local/bin/backup_dashboard.py
fi

if [ -n "${VERIFY_DB_CONTENT}" ]; then
    echo "${VERIFY_DB_CONTENT}" | sudo tee /usr/local/bin/verify_db.sh > /dev/null
    sudo chmod +x /usr/local/bin/verify_db.sh
fi

# 13. Configure Backup Cron Schedule
CRON_SCHEDULE="*/${LOG_INTERVAL} * * * *"
if [ "${LOG_INTERVAL}" -ge 60 ]; then
   CRON_SCHEDULE="0 * * * *"
fi

echo "# IBM Db2 Automated Backup Schedule" | sudo tee /etc/cron.d/db_backup > /dev/null

# 1. Log Backups (Every 15 min by default)
echo "${CRON_SCHEDULE} root DB_TYPE=db2 DB2_USER=${DB2_INSTANCE_USER} DB_NAME=${DB2_DB_NAME} BACKUP_MODE=log BACKUP_DIR=/var/lib/db2_backups INSTANCE_NAME=$(hostname) RETENTION_DAYS_LOG=${RETENTION_DAYS_LOG} /usr/local/bin/db_backup.sh >> /var/log/db_backup_log.log 2>&1" | sudo tee -a /etc/cron.d/db_backup

# 2. Full Backups (Daily at specified time, default 02:00 UTC)
if [ -n "${FULL_BACKUP_TIME}" ]; then
    IFS=':' read -r HH MM <<< "${FULL_BACKUP_TIME}"
    if [[ "$HH" =~ ^[0-9]+$ ]] && [[ "$MM" =~ ^[0-9]+$ ]]; then
        echo "${MM} ${HH} * * * root DB_TYPE=db2 DB2_USER=${DB2_INSTANCE_USER} DB_NAME=${DB2_DB_NAME} BACKUP_MODE=full BACKUP_DIR=/var/lib/db2_backups INSTANCE_NAME=$(hostname) RETENTION_DAYS_FULL=${RETENTION_DAYS_FULL} /usr/local/bin/db_backup.sh >> /var/log/db_backup_full.log 2>&1" | sudo tee -a /etc/cron.d/db_backup
    fi
fi

# 14. Configure Daily Dashboard Email Cron
EMAIL_FLAGS=""
if [ -n "${REPORT_RECIPIENTS}" ]; then
    EMAIL_FLAGS="--send-email --recipients '${REPORT_RECIPIENTS}'"
    if [ -n "${SMTP_HOST}" ]; then
        EMAIL_FLAGS="${EMAIL_FLAGS} --smtp-host '${SMTP_HOST}' --smtp-port ${SMTP_PORT}"
    fi
fi

echo "# Database Backup & Recovery Daily Health Dashboard Report" | sudo tee /etc/cron.d/backup_dashboard > /dev/null
echo "${REPORT_CRON_SCHEDULE} root /usr/local/bin/backup_dashboard.py --backup-dir /var/lib/db2_backups --data-dir /var/lib/db2_data --instance-name $(hostname) --db-type db2 --output-html /var/log/backup_dashboard.html ${EMAIL_FLAGS} >> /var/log/backup_dashboard_cron.log 2>&1" | sudo tee -a /etc/cron.d/backup_dashboard

echo "Db2 startup script execution complete."
