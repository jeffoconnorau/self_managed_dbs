#!/bin/bash
set -eo pipefail

DB_TYPE=$1
DATA_DIR_MOUNT="/dev/mapper/data_vg-data_lv"

echo "VERIFY_DB: --- Running verification for $DB_TYPE ---"

check_service() {
    local service_name=$1
    if systemctl is-active --quiet "$service_name"; then
        echo "VERIFY_DB:   SUCCESS: $service_name service is running."
    else
        echo "VERIFY_DB:   FAILURE: $service_name service is NOT running."
        exit 1
    fi
}

check_mount() {
    local path=$1
    local expected_device=$2
    # Ensure the path exists before checking the mount
    if [[ ! -d "$path" ]]; then
        echo "VERIFY_DB:   FAILURE: Data directory '$path' does not exist."
        exit 1
    fi
    local actual_device=$(df --output=source "$path" | tail -n 1)
    if [[ "$actual_device" == "$expected_device" ]]; then
        echo "VERIFY_DB:   SUCCESS: $path is mounted on $expected_device."
    else
        echo "VERIFY_DB:   FAILURE: $path is mounted on $actual_device, expected $expected_device."
        exit 1
    fi
}

if [[ "$DB_TYPE" == "mysql" ]]; then
    check_service mysqld
    # MySQL data dir is typically /var/lib/mysql, which is a symlink in our setup
    MYSQL_DATA_DIR="/var/lib/mysql"
    check_mount "$MYSQL_DATA_DIR" "$DATA_DIR_MOUNT"
    # Use the .my.cnf file created by the setup script for authentication
    echo "VERIFY_DB: --- Attempting MySQL connection --- "
    set -x # Enable debug output
    sudo mysql --defaults-file=/root/.my.cnf -e "SELECT 1;"
    mysql_exit_code=$?
    set +x # Disable debug output
    echo "VERIFY_DB: --- MySQL connection attempt finished --- "

    if [ ${mysql_exit_code} -eq 0 ]; then
        echo "VERIFY_DB:   SUCCESS: Can connect to MySQL."
        echo "VERIFY_DB:   --- MySQL Version ---"
        sudo mysql --defaults-file=/root/.my.cnf -e "SELECT version();"
        echo "VERIFY_DB:   --- MySQL Databases ---"
        sudo mysql --defaults-file=/root/.my.cnf -e "SHOW DATABASES;"
    else
        echo "VERIFY_DB:   FAILURE: Cannot connect to MySQL. Exit code: ${mysql_exit_code}"
        echo "VERIFY_DB:   --- MySQL Log --- "
        sudo tail -n 20 /var/log/mysqld.log
        exit 1
    fi

elif [[ "$DB_TYPE" == "postgres" ]]; then
    check_service postgresql
    # PostgreSQL data dir is typically /var/lib/postgresql/VERSION/main, which is a symlink
    PG_VERSION=$(ls /etc/postgresql/ | head -n 1)
    PG_DATA_DIR="/var/lib/postgresql/${PG_VERSION}/main"
    check_mount "$PG_DATA_DIR" "$DATA_DIR_MOUNT"
    # Ensure postgres user can read the directory (already checked mount, but let's check basic connectivity)
    
    # We use sudo -u postgres, so no password needed if using peer/ident auth which is default for local
    # But if we forced password, we might need PGPASSWORD. 
    # scripts/postgres_setup.sh set password to 'YourSecurePassword1!' but usually local postgres user connect via peer.
    # Let's verify connectivity:
    if sudo -u postgres psql -c "SELECT 1;" > /dev/null 2>&1; then
        echo "VERIFY_DB:   SUCCESS: Can connect to PostgreSQL."
        echo "VERIFY_DB:   --- PostgreSQL Version ---"
        sudo -u postgres psql -c "SELECT version();"
        echo "VERIFY_DB:   --- PostgreSQL Databases ---"
        sudo -u postgres psql -l
    else
        echo "VERIFY_DB:   FAILURE: Cannot connect to PostgreSQL."
        exit 1
    fi
else
    echo "VERIFY_DB:   FAILURE: Unknown DB_TYPE '$DB_TYPE'. Use 'mysql' or 'postgres'."
    exit 1
fi

echo "VERIFY_DB: --- $DB_TYPE verification complete. ---"
exit 0
