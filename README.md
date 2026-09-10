# Self-Managed Databases on Google Compute Engine with Terraform

The primary goal of this repository is to provision a robust, self-managed database environment with **automated, cron-scheduled backups** and **daily operational reporting**.

This project establishes Google Compute Engine VMs running self-managed relational database systems that continuously back up to dedicated local persistent disks. Once this environment is active, it is **highly recommended** to protect the dedicated backup disk on each VM using [Google Cloud Backup and DR](https://cloud.google.com/backup-disaster-recovery) via the Backup Vault - Disks protection feature (or Backup Vault - VM protection).

The repository provides automated, modular provisioning and backup automation for three major database engines, each of which can be optionally enabled and provisioned on your preferred Linux distribution:

1.  **MySQL 8.0** (Configurable on Rocky Linux 9, RHEL 9/8, Ubuntu 22.04, or Debian 12)
2.  **PostgreSQL 14** (Configurable on Ubuntu 22.04 LTS, Debian 12, Rocky Linux 9, or RHEL 9)
3.  **IBM Db2 11.5** (Configurable on certified enterprise Linux: Rocky Linux 9, RHEL 9/8, SLES 15, or Ubuntu 22.04 LTS)

---

## Key Features

*   **Unified Backup Architecture (`scripts/db_backup.sh`):**
    *   **Full Backups:** Regularly scheduled online database snapshots (default: daily at 02:00 UTC).
    *   **Log Backups:** Frequent continuous transaction log archives (default: every 15 minutes) enabling **Point-in-Time Recovery (PITR)**.
    *   **Automated Retention:** Independent lifecycle retention policies for full and log backups (default: 3 days).
    *   **Hierarchical Storage:** Dedicated backup disks organized by host, backup type (`full`/`logs`), and date.
*   **IBM Db2 Enterprise Support:**
    *   Full compatibility with IBM-supported Linux distributions (RHEL, SLES, Ubuntu LTS, Rocky Linux).
    *   Automated LVM disk partitioning and kernel parameter tuning for Db2.
    *   Unattended silent installation via response file (`db2server.rsp`) and helper automation (`install_db2.sh`).
    *   Native integration with Db2 continuous log archiving (`LOGARCHMETH1`) and online compressed backups.
*   **Daily Backup & Recovery Health Dashboard (`scripts/backup_dashboard.py`):**
    *   Dark-themed, high-fidelity HTML dashboard matching modern operational observability standards ([preview sample report](sample_dashboard.html)).
    *   Automated daily email delivery to stakeholders on a cron schedule.
    *   Insights on:
        1. **Backup Times & Durations:** Exact timestamps, elapsed times, and execution status.
        2. **Achieved RPO & SLA Compliance:** Real-time calculation of Recovery Point Objective (RPO) based on recent log timestamps against the 15-minute SLA.
        3. **Storage Consumed:** Total capacity, used space, free space, and breakdown between Full Backups and Incremental Logs.
        4. **Local Disk Recovery Window:** Precise period of time continuous Point-in-Time Recovery is guaranteed from local disk (e.g., *3.4 days from 2026-09-07 02:00 to 2026-09-10 13:45 UTC*).

---

## Architectural Comparison: Transaction Log Management

While all three engines follow the same 15-minute schedule, their native log archiving mechanisms align with their engine-specific capabilities:

| Feature | PostgreSQL 14 | MySQL 8.0 | IBM Db2 11.5 |
| :--- | :--- | :--- | :--- |
| **Archival Model** | **Push-based (Continuous)** | **Pull-based (Incremental Marker)** | **Push-to-Staging (Native Archive)** |
| **Native Mechanism** | `archive_command` in `postgresql.conf` | `FLUSH BINARY LOGS` + binlog rotation | `LOGARCHMETH1 = 'DISK:...'` |
| **Active Log Switch** | `SELECT pg_switch_wal();` | `FLUSH BINARY LOGS;` | `ARCHIVE LOG FOR DATABASE <db>` |
| **Log Storage Staging** | `wal_staging` directory on backup disk | Live datadir (`/var/lib/mysql`) | `log_staging` directory on backup disk |
| **Cron Ingestion** | Sweeps and moves WAL files from staging to `logs/YYYY-MM-DD` | Pulls newly modified binlogs newer than marker file into `logs/YYYY-MM-DD` | Sweeps closed archive logs from staging to `logs/YYYY-MM-DD` |
| **Log Pruning** | Handled by directory retention cleanup | `PURGE BINARY LOGS BEFORE NOW() - INTERVAL X DAY` | `db2 prune history <timestamp> and delete` + directory cleanup |
| **Full Backup Method** | `pg_basebackup -Ft -z -X fetch` | `mysqldump --single-transaction --flush-logs --master-data=2` | `db2 backup database <db> online to <dir> compress` |

---

## IBM Db2 Architecture & Installation Guide

### 1. Supported Linux Distributions

IBM officially restricts and certifies Db2 only on specific enterprise Linux distributions with compatible glibc versions, kernel interfaces, and PAM/numactl libraries. This repository allows you to configure your desired Linux flavour via the `db2_linux_flavor` Terraform variable:

| Distribution Flavor | `db2_linux_flavor` Value | GCE Base Image | Notes |
| :--- | :--- | :--- | :--- |
| **Ubuntu 22.04 LTS** *(Default)* | `"ubuntu-2204"` | `ubuntu-os-cloud/ubuntu-2204-lts` | Validated for Db2 11.5.7+ / 11.5.8+. |
| **Rocky Linux 9** | `"rocky-linux-9"` | `rocky-linux-cloud/rocky-linux-9` | Binary-compatible RHEL 9 rebuild. No subscription required. |
| **Red Hat Enterprise Linux 9** | `"rhel-9"` | `rhel-cloud/rhel-9` | IBM primary enterprise reference platform. |
| **Red Hat Enterprise Linux 8** | `"rhel-8"` | `rhel-cloud/rhel-8` | Fully certified for Db2 11.5 LTS. |
| **SUSE Linux Enterprise 15** | `"sles-15"` | `suse-cloud/sles-15` | SLES 15 SP1–SP5 officially supported. |

### 2. Automatic System & Kernel Prerequisites

The startup script `scripts/db2_setup.sh` automatically configures the mandatory operating system parameters:
*   **Kernel Tuning (`/etc/sysctl.d/99-db2.conf`):**
    *   `kernel.shmmax = 18446744073709551615`
    *   `kernel.shmall = 268435456`
    *   `kernel.sem = 250 1024000 32 4096`
    *   `kernel.msgmax = 65536`, `kernel.msgmni = 2048`
    *   `vm.max_map_count = 262144`
*   **User Security Limits (`/etc/security/limits.d/99-db2.conf`):**
    *   `db2inst1 soft/hard nofile 65536`
    *   `db2inst1 soft/hard nproc 32768`
    *   `db2inst1 soft/hard data/fsize unlimited (-1)`
*   **LVM Storage:**
    *   Persistent Data Disk (`/dev/sdb`) &rarr; `/var/lib/db2_data` (hosting instance owner home `/var/lib/db2_data/db2inst1`)
    *   Dedicated Backup Disk (`/dev/sdc`) &rarr; `/var/lib/db2_backups` (hosting `log_staging`, `full/`, and `logs/`)

### 3. Db2 Installation Steps

Because IBM Db2 requires accepting an IBM license agreement and obtaining an installation archive (Community Edition or Enterprise edition from IBM Passport Advantage), installation can be performed in either of two ways:

#### Option A: Fully Automated via Cloud Storage Bucket
If you place the Db2 installation archive (e.g. `v11.5.8_linuxx64_server_dec.tar.gz`) in a Cloud Storage bucket accessible by the VM:

1.  Set the variable in `terraform.tfvars`:
    ```terraform
    db2_installer_url = "gs://your-artifact-bucket/v11.5.8_linuxx64_server_dec.tar.gz"
    ```
2.  Run `terraform apply`. The startup script will automatically download the package, execute the silent response file, create instance `db2inst1`, configure archive logging to the backup disk, perform the initial baseline backup, and enable `systemctl enable db2`.

#### Option B: Manual One-Command Installation via Helper Script
If you prefer to copy the installer tarball to the VM after boot:

1.  Provision the VM:
    ```bash
    terraform apply -target=google_compute_instance.db2_vm -target=google_compute_disk.db2_data_disk -target=google_compute_disk.db2_backup_disk
    ```
2.  Copy your Db2 installation package to the VM:
    ```bash
    gcloud compute scp v11.5.8_linuxx64_server_dec.tar.gz db2-backup-vm:/tmp/db2.tar.gz --zone <zone>
    ```
3.  SSH into the VM and run the pre-staged helper script:
    ```bash
    gcloud compute ssh db2-backup-vm --zone <zone>
    sudo /usr/local/bin/install_db2.sh /tmp/db2.tar.gz
    ```
    This helper script automatically:
    *   Extracts the archive to `/var/lib/db2_data/db2_extracted` (leveraging the persistent data disk rather than filling the root OS disk).
    *   Runs `db2setup` against `/var/lib/db2_data/db2server.rsp` (or `db2_install`).
    *   Configures `db2icrt` with instance user `db2inst1` and fenced user `db2fenc1`.
    *   Cleans up temporary extraction files to preserve disk space.
    *   Creates database `db1`.
    *   Configures continuous archive logging:
        ```bash
        db2 "UPDATE DB CFG FOR db1 USING LOGARCHMETH1 'DISK:/var/lib/db2_backups/<HOSTNAME>/log_staging'"
        ```
    *   Synchronously restarts the Db2 engine (`db2stop force && db2start`) to clear all connections and locks.
    *   Performs the mandatory initial offline baseline backup (`full/initial/`) to clear the **`BACKUP PENDING`** state.
    *   Activates the database (`db2 activate db db1`).
    *   Verifies database connectivity against `sysibm.sysdummy1`.

### 4. Key Operational Notes & Testing Insights

During live verification on Google Compute Engine, several critical enterprise Linux and Db2 integration requirements were identified and automated:

*   **Systemd `RemoveIPC=no` Requirement:**
    *   **The Problem:** Modern Linux distributions with systemd (Ubuntu 20.04+, RHEL 8/9, Rocky 9) enable `RemoveIPC=yes` by default in `/etc/systemd/logind.conf`. When a user session or subshell exits (such as `su - db2inst1 -c "..."`), systemd automatically sweeps and destroys all IPC message queues, semaphores, and shared memory segments owned by the user.
    *   **The Symptom:** Subsequent Db2 CLP commands fail with `DB21017E The Command Line Processor encountered a system error with the front-end process output queue. Reason code = -2029060030` and `SQL1032N No start database manager command was issued`.
    *   **The Fix:** Automated in `scripts/db2_setup.sh` via `/etc/systemd/logind.conf.d/99-db2.conf` setting `RemoveIPC=no`.
*   **Db2 `BACKUP PENDING` State Transition:**
    *   Enabling archive logging (`LOGARCHMETH1`) immediately forces Db2 into `BACKUP PENDING` state.
    *   While in `BACKUP PENDING`, database connections and `ACTIVATE DATABASE` commands will fail with `SQL1035N`.
    *   An **offline** full backup must be executed before activating or connecting. To ensure exclusive access, the engine must be restarted (`db2stop force && db2start`) to terminate any transitioning connection handles before taking the initial backup image.
*   **Multiarch 32-bit Compatibility (`DBT3514W`):**
    *   During installation, `db2prereqcheck` may output warnings (`DBT3514W`) regarding missing 32-bit libraries (`/lib/i386-linux-gnu/libpam.so*` and `libstdc++.so.6`).
    *   These warnings are purely informational for legacy 32-bit client libraries; the 64-bit Db2 server runs natively on 64-bit Ubuntu.
    *   `scripts/db2_setup.sh` automatically enables `dpkg --add-architecture i386` and installs `libpam0g:i386` and `libstdc++6:i386` so subsequent installations pass cleanly with zero warnings.
*   **Recommended Sizing (Minimum 4 vCPUs / 16 GB RAM):**
    *   Db2 manages extensive shared memory sets, buffer pools, and concurrent compile agents. The VM machine type defaults to **`e2-standard-4`** (4 vCPUs, 16 GB RAM) to ensure fast compilation, response-file execution, and optimal database performance.
*   **Passwordless Sudo for OS Login:**
    *   Setup scripts automatically configure `/etc/sudoers.d/99-all-nopasswd` so administrators and Google Cloud OS Login users can manage services and cron jobs without authentication obstacles.

---

## Daily Backup & Recovery Health Dashboard

Each database VM is equipped with `scripts/backup_dashboard.py`, which continuously tracks and audits backup operations.

### Dashboard Capabilities

1.  **Backup Execution Times & Durations:**
    *   Tracks the exact UTC timestamps and completion times for both full snapshots and 15-minute incremental log backups.
    *   Maintains a chronological activity history of recent backup artifacts.
2.  **Achieved Recovery Point Objective (RPO):**
    *   Calculates the real-time gap between the current time and the newest continuous transaction log on disk.
    *   Monitors compliance against the configured SLA (`log_backup_interval_minutes`, default: 15m):
        *   **Optimal (&le; 15m):** RPO met. Continuous transactions fully protected.
        *   **Warning (15m &ndash; 30m):** Log archival delayed.
        *   **Critical (> 30m):** Log archival interrupted or backup missing.
3.  **Storage Capacity & Volume Breakdown:**
    *   **Dedicated Backup Storage Volume:** Reports volume name (`backup_vg/backup_lv`), mount point (e.g. `/var/lib/db2_backups`), total capacity, used space, free space, and a visual allocation breakdown between **Full Base Backups** and **Continuous Archive Logs (PITR)**.
    *   **Production Data Volume:** Reports volume name (`data_vg/data_lv`), mount point (e.g. `/var/lib/db2_data`), total capacity, database data consumed, and remaining **Growth Headroom** (free space & percentage available).
4.  **Local Disk Recovery Window (Point-in-Time Recovery):**
    *   Calculates the continuous time window during which the database can be restored to any second directly from local disk without accessing external tape or cold vaults.
    *   Calculated from the oldest valid full baseline image up to the newest archived transaction log.
    *   Example: `3.4 Days (2026-09-07 02:00:00 to 2026-09-10 13:45:00 UTC)`.

### Scheduled Email Reports

The dashboard runs automatically on a cron schedule (`/etc/cron.d/backup_dashboard`, default: daily at `08:00 UTC`).

If email recipients are configured in `terraform.tfvars`:
```terraform
report_recipients    = "dba-team@example.com,devops@example.com"
report_cron_schedule = "0 8 * * *"

# Optional SMTP relay configuration
smtp_host            = "smtp.sendgrid.net"
smtp_port            = 587
smtp_user            = "apikey"
smtp_password        = "your-secret-api-key"
```

The report is rendered into a responsive HTML email and dispatched directly to the distribution list. If external SMTP is not configured, the script automatically attempts local delivery via `/usr/sbin/sendmail` or logs the report locally at `/var/log/backup_dashboard.html`.

### Running the Health Dashboard Report On-Demand

You can generate the HTML report on-demand on any database VM to audit backup performance, verify SLA compliance, or test email dispatch.

#### 1. Generate Local HTML Dashboard

Run the dashboard generator directly for your specific database engine (if `--data-dir` is omitted, the script automatically inspects the default production mount):

*   **IBM Db2 VM:**
    ```bash
    sudo /usr/local/bin/backup_dashboard.py \
        --backup-dir /var/lib/db2_backups \
        --data-dir /var/lib/db2_data \
        --instance-name $(hostname) \
        --db-type db2 \
        --output-html /tmp/backup_dashboard.html
    ```

*   **MySQL VM:**
    ```bash
    sudo /usr/local/bin/backup_dashboard.py \
        --backup-dir /var/lib/mysql_backups \
        --data-dir /var/lib/mysql_data \
        --instance-name $(hostname) \
        --db-type mysql \
        --output-html /tmp/backup_dashboard.html
    ```

*   **PostgreSQL VM:**
    ```bash
    sudo /usr/local/bin/backup_dashboard.py \
        --backup-dir /var/lib/postgresql_backups \
        --data-dir /var/lib/postgresql_data \
        --instance-name $(hostname) \
        --db-type postgres \
        --output-html /tmp/backup_dashboard.html
    ```

#### 2. View Report Summary in Terminal

You can inspect the generated report structure:
```bash
head -n 50 /tmp/backup_dashboard.html
```

#### 3. Test On-Demand Email Dispatch

To test emailing the report immediately to one or more recipients:

*   **Via Local MTA (`sendmail`):**
    ```bash
    sudo /usr/local/bin/backup_dashboard.py \
        --backup-dir /var/lib/db2_backups \
        --instance-name $(hostname) \
        --db-type db2 \
        --send-email \
        --recipients "admin@example.com"
    ```

*   **Via Authenticated SMTP Relay (e.g. SendGrid, Mailgun, Gmail):**
    ```bash
    sudo /usr/local/bin/backup_dashboard.py \
        --backup-dir /var/lib/db2_backups \
        --instance-name $(hostname) \
        --db-type db2 \
        --send-email \
        --recipients "admin@example.com,dba-team@example.com" \
        --smtp-host "smtp.sendgrid.net" \
        --smtp-port 587 \
        --smtp-user "apikey" \
        --smtp-password "your-smtp-api-key"
    ```

#### 4. Preview Dashboard with Sample Data (Local Workstation)

A complete, pre-rendered, and sanitized example report generated from a live IBM Db2 environment is included in the root of this repository:
```bash
open sample_dashboard.html  # macOS
# or view sample_dashboard.html in any web browser
```

Alternatively, you can generate a fresh mock preview on your workstation at any time:
```bash
python3 scripts/backup_dashboard.py --sample-data --output-html ./preview_dashboard.html
open ./preview_dashboard.html  # macOS
```

---

## Configuration Variables Reference

| Variable | Description | Default |
| :--- | :--- | :--- |
| `project_id` | The GCP project ID. | *Required* |
| `region` | GCP region for resources. | `"us-central1"` |
| `zone` | GCP zone for resources. | `"us-central1-a"` |
| `db_password` | Master password for database instances. | *Required (Sensitive)* |
| `vm_machine_type` | Machine type for the VMs (4 vCPUs, 16 GB RAM recommended). | `"e2-standard-4"` |
| `mysql_machine_type` | Optional machine type override for MySQL VM. | `null` (uses `vm_machine_type`) |
| `postgres_machine_type` | Optional machine type override for PostgreSQL VM. | `null` (uses `vm_machine_type`) |
| `db2_machine_type` | Optional machine type override for Db2 VM. | `null` (uses `vm_machine_type`) |
| **MySQL Options** | | |
| `enable_mysql_vm` | Enable or disable provisioning the MySQL VM. | `true` |
| `mysql_vm_name` | Hostname for the MySQL VM. | `"rocky-mysql-vm"` |
| `mysql_linux_flavor` | Linux OS flavor for MySQL (`rocky-linux-9`, `rhel-9`, `rhel-8`, `ubuntu-2204`, `debian-12`). | `"rocky-linux-9"` |
| `mysql_db_name` | Name of default MySQL database. | `"db1"` |
| **PostgreSQL Options** | | |
| `enable_postgres_vm` | Enable or disable provisioning the PostgreSQL VM. | `true` |
| `postgres_vm_name` | Hostname for the PostgreSQL VM. | `"ubuntu-postgres-vm"` |
| `postgres_linux_flavor` | Linux OS flavor for PostgreSQL (`ubuntu-2204`, `debian-12`, `rocky-linux-9`, `rhel-9`). | `"ubuntu-2204"` |
| `postgres_db_name` | Name of default PostgreSQL database. | `"db1"` |
| **IBM Db2 Options** | | |
| `enable_db2_vm` | Enable or disable provisioning the IBM Db2 VM. | `true` |
| `db2_vm_name` | Hostname for the IBM Db2 VM. | `"db2-backup-vm"` |
| `db2_linux_flavor` | Linux OS flavor for Db2 (`ubuntu-2204`, `rocky-linux-9`, `rhel-9`, `rhel-8`, `sles-15`). | `"ubuntu-2204"` |
| `db2_db_name` | Name of default Db2 database. | `"db1"` |
| `db2_instance_user`| Db2 instance owner username. | `"db2inst1"` |
| `db2_installer_url`| Optional GCS or HTTPS URL to Db2 tarball. | `""` |
| **Backup & Retention** | | |
| `backup_retention_days_full` | Retention period for full snapshots (days). | `3` |
| `backup_retention_days_log`  | Retention period for transaction logs (days). | `3` |
| `full_backup_interval_hours` | Interval for full backups (hours). | `24` |
| `log_backup_interval_minutes`| Interval for transaction log backups (minutes). | `15` |
| `full_backup_time` | UTC time for daily full backup (`HH:MM`). | `"02:00"` |
| **Dashboard & Email** | | |
| `report_cron_schedule` | Cron schedule for the daily dashboard report. | `"0 8 * * *"` |
| `report_recipients` | Comma-separated list of report recipient emails. | `""` |
| `smtp_host` | SMTP server host for email dispatch. | `""` |
| `smtp_port` | SMTP server port. | `587` |

---

## Deployment Instructions

### 1. Initialize and Configure

```bash
git clone https://github.com/jeffoconnorau/self_managed_dbs
cd self_managed_dbs

cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` to select which database engines to enable and their OS flavours:
```terraform
project_id  = "my-gcp-project"
region      = "asia-southeast1"
zone        = "asia-southeast1-a"
db_password = "SecurePassword123!"

# 1. MySQL VM
enable_mysql_vm    = true
mysql_linux_flavor = "rocky-linux-9"  # or "ubuntu-2204", "rhel-9", "debian-12"

# 2. PostgreSQL VM
enable_postgres_vm    = true
postgres_linux_flavor = "ubuntu-2204" # or "debian-12", "rocky-linux-9"

# 3. IBM Db2 VM
enable_db2_vm    = false              # Set to true to deploy Db2
db2_linux_flavor = "ubuntu-2204"      # or "rocky-linux-9", "rhel-9", "sles-15"

# 4. Automated Daily Backup & Recovery Health Email Dashboard
report_recipients    = "dba-team@example.com"
report_cron_schedule = "0 8 * * *"
```

### 2. Provision Resources

```bash
terraform init
terraform plan
terraform apply -auto-approve
```

### 3. Connecting to the VMs

Use `gcloud` to SSH through Google Cloud Identity-Aware Proxy (IAP):

*   **Rocky Linux / MySQL VM:**
    ```bash
    gcloud compute ssh rocky-mysql-vm --zone <zone>
    ```
*   **Ubuntu / PostgreSQL VM:**
    ```bash
    gcloud compute ssh ubuntu-postgres-vm --zone <zone>
    ```
*   **IBM Db2 VM:**
    ```bash
    gcloud compute ssh db2-backup-vm --zone <zone>
    ```

---

## Verification & Testing

### 1. Database Health & Mount Verification

The unified verification script `/usr/local/bin/verify_db.sh` is automatically deployed to all VMs. It validates daemon process status, LVM persistent disk mounting, and database connectivity.

SSH into any provisioned VM and execute:

*   **IBM Db2 VM:**
    ```bash
    sudo /usr/local/bin/verify_db.sh db2
    ```
    *Checks `db2sysc` process, `/var/lib/db2_data` mount, `db2level`, connection to `db1`, query against `sysibm.sysdummy1`, and `LOGARCHMETH1`.*

*   **MySQL VM:**
    ```bash
    sudo /usr/local/bin/verify_db.sh mysql
    ```
    *Checks `mysqld` service, `/var/lib/mysql` mount, connection via `/root/.my.cnf`, version query, and database listing.*

*   **PostgreSQL VM:**
    ```bash
    sudo /usr/local/bin/verify_db.sh postgres
    ```
    *Checks `postgresql` service, data directory mount, peer authentication connectivity, and database listing.*

---

### 2. Running On-Demand Backup Jobs

In addition to the automated cron schedules, you can trigger full and incremental log backups on demand using `/usr/local/bin/db_backup.sh`.

#### A. IBM Db2 On-Demand Backups

*   **On-Demand Full Backup (Online Compressed):**
    ```bash
    sudo DB_TYPE=db2 DB2_USER=db2inst1 DB_NAME=db1 BACKUP_MODE=full \
         BACKUP_DIR=/var/lib/db2_backups INSTANCE_NAME=$(hostname) \
         /usr/local/bin/db_backup.sh
    ```
    *   Executes `db2 backup database db1 online to /var/lib/db2_backups/.../full/YYYY-MM-DD compress`.
    *   Runs online without locking tables or interrupting database applications.
    *   Updates the `last_full_backup_timestamp` marker file and applies full backup retention.

*   **On-Demand Log Backup (Force Archival & Staging Sweep):**
    ```bash
    sudo DB_TYPE=db2 DB2_USER=db2inst1 DB_NAME=db1 BACKUP_MODE=log \
         BACKUP_DIR=/var/lib/db2_backups INSTANCE_NAME=$(hostname) \
         /usr/local/bin/db_backup.sh
    ```
    *   Executes `db2 archive log for database db1` to truncate and close the currently active transaction log extent.
    *   Sweeps all closed log extents from `/var/lib/db2_backups/<HOSTNAME>/log_staging/` into dated directory `/var/lib/db2_backups/<HOSTNAME>/logs/YYYY-MM-DD/`.
    *   Prunes recovery history records older than the retention window (`db2 prune history <ts> and delete`).

#### B. MySQL On-Demand Backups

*   **On-Demand Full Backup (Consistent Snapshot):**
    ```bash
    sudo DB_TYPE=mysql BACKUP_MODE=full \
         BACKUP_DIR=/var/lib/mysql_backups INSTANCE_NAME=$(hostname) \
         /usr/local/bin/db_backup.sh
    ```
    *   Executes `mysqldump` with `--single-transaction --flush-logs --master-data=2`.
    *   Flushes binlogs to establish a clean point-in-time boundary, generates compressed `.sql.gz` snapshot in `full/YYYY-MM-DD/`.
    *   Applies full snapshot retention pruning.

*   **On-Demand Log Backup (Binary Log Rotation & Pull):**
    ```bash
    sudo DB_TYPE=mysql BACKUP_MODE=log \
         BACKUP_DIR=/var/lib/mysql_backups INSTANCE_NAME=$(hostname) \
         /usr/local/bin/db_backup.sh
    ```
    *   Executes `FLUSH BINARY LOGS;` to close active binlog.
    *   Identifies new binlog files modified since the last marker run and syncs them to `logs/YYYY-MM-DD/`.
    *   Executes `PURGE BINARY LOGS BEFORE NOW() - INTERVAL X DAY` to purge obsolete live binlogs.

#### C. PostgreSQL On-Demand Backups

*   **On-Demand Full Backup (Base Snapshot):**
    ```bash
    sudo DB_TYPE=postgres BACKUP_MODE=full \
         BACKUP_DIR=/var/lib/postgresql_backups INSTANCE_NAME=$(hostname) \
         /usr/local/bin/db_backup.sh
    ```
    *   Executes `pg_basebackup -Ft -z -X fetch` generating compressed `base.tar.gz`.
    *   Labels snapshot with checkpoint LSN and stores in `full/YYYY-MM-DD/`.
    *   Applies full base backup retention pruning.

*   **On-Demand Log Backup (WAL Switch & Staging Sweep):**
    ```bash
    sudo DB_TYPE=postgres BACKUP_MODE=log \
         BACKUP_DIR=/var/lib/postgresql_backups INSTANCE_NAME=$(hostname) \
         /usr/local/bin/db_backup.sh
    ```
    *   Executes `SELECT pg_switch_wal();` to switch out of the active WAL segment.
    *   Sweeps completed WAL files from staging area `wal_staging/` into `logs/YYYY-MM-DD/`.
    *   Applies transaction log retention cleanup.

---

## Disk Layout & Mounts

Each VM is provisioned with three dedicated Persistent Disks:

*   `/dev/sda` (OS Disk &rarr; `/`): Operating system and system packages.
*   `/dev/sdb` (Data Disk &rarr; `/dev/data_vg/data_lv`):
    *   MySQL: Mounted at `/var/lib/mysql_data`
    *   PostgreSQL: Mounted at `/var/lib/postgresql_data`
    *   IBM Db2: Mounted at `/var/lib/db2_data` (hosting instance owner home `/var/lib/db2_data/db2inst1`)
*   `/dev/sdc` (Backup Disk &rarr; `/dev/backup_vg/backup_lv`):
    *   MySQL: Mounted at `/var/lib/mysql_backups`
    *   PostgreSQL: Mounted at `/var/lib/postgresql_backups`
    *   IBM Db2: Mounted at `/var/lib/db2_backups`

### Backup Directory Hierarchy on Backup Disk
```
/var/lib/<db>_backups/<INSTANCE_NAME>/
├── full/
│   ├── 2026-09-08/
│   ├── 2026-09-09/
│   └── 2026-09-10/
├── logs/
│   ├── 2026-09-08/
│   ├── 2026-09-09/
│   └── 2026-09-10/
├── log_staging/          # Staging area for continuous Db2/Postgres logs
└── last_full_backup_timestamp
```

---

## Destroying Resources

To tear down all provisioned instances, disks, routers, and networks:

```bash
terraform destroy -auto-approve
```
