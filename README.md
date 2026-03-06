# Self-Managed Databases on Google Compute Engine with Terraform

The primary goal of this repository is to provision a robust, self-managed database environment with **automated, cron-scheduled backups**.

It provisions two Google Compute Engine VMs:

1.  **Rocky Linux 9** running **MySQL 8.0**
2.  **Ubuntu 22.04 LTS** running **PostgreSQL 14**

## Backup Features

The core feature is the unified `scripts/db_backup.sh` script, which provides:
*   **Full Backups:** regularly scheduled snapshots (default: daily).
*   **Log Backups:** frequent incremental backups (default: every 15 minutes) for Point-in-Time Recovery (PITR).
*   **Retention:** automated cleanup of old backups (default: 3 days).
*   **Hierarchical Storage:** backups are organized by type (`full`/`logs`) and date on a dedicated backup disk.

### Backup Configuration

Backups are handled by `scripts/db_backup.sh` and triggered via a system cron job located at `/etc/cron.d/db_backup`.

The following Terraform variables control the backup settings:

| Variable | Description | Default |
| :--- | :--- | :--- |
| `backup_retention_days_full` | Retention period for full backups (days). | `3` |
| `backup_retention_days_log` | Retention period for log backups (days). | `3` |
| `full_backup_interval_hours` | Frequency of full backups (hours). | `24` |
| `log_backup_interval_minutes` | Frequency of log backups (minutes). | `15` |
| `full_backup_time` | Specific time to force full backups (HH:MM UTC). | `"02:00"` |

### Backup Scheduling

The setup scripts configure two distinct cron jobs for clean separation:

1.  **Log Backups:** Runs every `log_backup_interval_minutes` (default 15m).
    *   Command: `BACKUP_MODE=log ...`
    *   Retention: Uses `backup_retention_days_log` only.
2.  **Full Backups:** Runs daily at `full_backup_time` (default 02:00 UTC).
    *   Command: `BACKUP_MODE=full ...`
    *   Retention: Uses `backup_retention_days_full` only.

*Note: If `full_backup_time` is unset, the system falls back to a legacy hourly check that triggers a full backup only if `full_backup_interval_hours` has passed.*


**Directory Structure:**
Backups are stored in `/mnt/backup` (mapped to `/var/lib/mysql_backups` or `/var/lib/postgresql_backups`):
- `/<INSTANCE_NAME>/full/<YYYY-MM-DD>/`
- `/<INSTANCE_NAME>/logs/<YYYY-MM-DD>/`


## Prerequisites

1.  **Google Cloud SDK:** Install and initialize `gcloud` ([SDK Install Guide](https://cloud.google.com/sdk/docs/install)).
2.  **Terraform:** Install Terraform CLI ([Terraform Install Guide](https://learn.hashicorp.com/tutorials/terraform/install-cli)). Version ~> 7.20.0 for the Google provider is required.
3.  **GCP Project:** Have a GCP project with billing enabled.
4.  **Permissions:** Ensure your GCP account has necessary permissions to create VPCs, Subnets, Firewall Rules, Compute Instances, Disks, Cloud Routers, and Cloud NAT.

## Directory Structure

```
.
├── main.tf             # Main Terraform configuration
├── variables.tf        # Variable declarations
├── terraform.tfvars.example # Example variable values (rename to terraform.tfvars)
├── outputs.tf          # Outputs
├── scripts/
│   ├── mysql_setup.sh  # Startup script for Rocky/MySQL
│   ├── postgres_setup.sh # Startup script for Ubuntu/PostgreSQL
│   └── verify_db.sh    # Verification script for both DBs
└── README.md           # This file
```

## Configuration Steps

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/jeffoconnorau/self_managed_dbs
    cd self_managed_dbs
    ```

2.  **Configure Variables:**
    Edit the `terraform.tfvars` file to match your GCP environment. Key variables:

    ```terraform
    project_id = "Your-GCP-Project-ID"  # Replace with your actual GCP Project ID
    region     = "us-central1"          # Optional: Change to your desired region
    zone       = "us-central1-a"        # Optional: Change to your desired zone

    # Optional: Configure existing or new network details
    network_name = "self-managed-dbs-vpc"    # Name for the VPC
    subnetwork_name = "self-managed-dbs-subnet" # Name for the Subnet
    subnetwork_ip_cidr_range = "10.128.0.0/20" # CIDR range for the Subnet

    # Optional: Customize default database names
    mysql_db_name = "db1"
    postgres_db_name = "db1"
    ```
    The startup scripts will create a database with the name specified in `mysql_db_name` or `postgres_db_name` on the respective instances.

3.  **Initialize Terraform:**
    This downloads necessary provider plugins.
    ```bash
    terraform init
    ```

4.  **Plan the deployment:**
    Review the changes Terraform will make.
    ```bash
    terraform plan
    ```

5.  **Apply the configuration:**
    This provisions all the resources in your GCP project.
    ```bash
    terraform apply -auto-approve
    ```
    The startup scripts will run on the first boot of each VM to install and configure the databases, including creating a database named as per the variables.

## Database Versions and Automation

This setup automates the installation and basic configuration of:

*   **MySQL 8.0** on Rocky Linux 9
*   **PostgreSQL 14** on Ubuntu 22.04 LTS

The entire database environment setup is handled by the scripts in the `scripts/` directory, which are executed on the first boot of each VM via instance metadata.

### Skipping Database Installation

If you only want to provision the VMs with the configured disks and networking, but *without* installing the databases, you can prevent the startup scripts from running. To do this, edit the `main.tf` file and comment out the `metadata_startup_script` attribute within the `google_compute_instance` resource blocks for the VMs you don't want to auto-configure.

For example, to prevent MySQL installation on `rocky_mysql_vm`:

```terraform
resource "google_compute_instance" "rocky_mysql_vm" {
  # ... other configuration ...

  metadata = {
    # Comment out the following line to disable automatic MySQL setup
    # metadata_startup_script = file("${path.module}/scripts/mysql_setup.sh")
    MYSQL_DB_NAME = var.mysql_db_name
  }

  # ... other configuration ...
}
```

Similarly, you can comment out the line in the `ubuntu_postgres_vm` resource to prevent PostgreSQL installation. After making these changes, run `terraform apply`.

## Deploying Single Instances (Optional)

If you only need to test one database type, you can target specific resources:

*   **To deploy only the MySQL VM and its resources:**
    ```bash
    terraform apply -auto-approve -target=google_compute_instance.rocky_mysql_vm -target=google_compute_disk.rocky_data_disk -target=google_compute_disk.rocky_backup_disk
    ```
    *Note: This assumes the network resources are already present or you include them in the targets.*

*   **To deploy only the PostgreSQL VM and its resources:**
    ```bash
    terraform apply -auto-approve -target=google_compute_instance.ubuntu_postgres_vm -target=google_compute_disk.ubuntu_data_disk -target=google_compute_disk.ubuntu_backup_disk
    ```
    *Note: This assumes the network resources are already present or you include them in the targets.*

    To target network resources as well, add:
    `-target=google_compute_network.vpc_network -target=google_compute_subnetwork.subnet -target=google_compute_firewall.allow_ssh -target=google_compute_router.router -target=google_compute_router_nat.nat`

## Connecting to the VMs

SSH access is facilitated via `gcloud`. The VMs do not have external IP addresses. Use the commands provided in the Terraform output:

*   **To SSH into the Rocky/MySQL VM:**
    ```bash
    # Use the command from terraform output 'ssh_command_rocky'
    ```

*   **To SSH into the Ubuntu/PostgreSQL VM:**
    ```bash
    # Use the command from terraform output 'ssh_command_ubuntu'
    ```

## Verifying Database Installations

A verification script `scripts/verify_db.sh` is included. You need to copy it to each VM and run it.

Get your project ID and zone from your `terraform.tfvars` file.

```bash
PROJECT_ID="$(grep project_id terraform.tfvars | cut -d '=' -f 2 | tr -d ' "')"
ZONE="$(grep zone terraform.tfvars | cut -d '=' -f 2 | tr -d ' "')"
```

1.  **Copy the script to the VMs:**

    *   For Rocky/MySQL:
        ```bash
        gcloud compute scp scripts/verify_db.sh rocky-mysql-vm:~ --project $PROJECT_ID --zone $ZONE
        ```

    *   For Ubuntu/PostgreSQL:
        ```bash
        gcloud compute scp scripts/verify_db.sh ubuntu-postgres-vm:~ --project $PROJECT_ID --zone $ZONE
        ```

2.  **SSH into the VM and Run the script:**

    *   **Rocky/MySQL VM:**
        ```bash
        gcloud compute ssh --project $PROJECT_ID --zone $ZONE rocky-mysql-vm

        # Once inside:
        chmod +x verify_db.sh
        sudo ./verify_db.sh mysql
        ```

    *   **Ubuntu/PostgreSQL VM:**
        ```bash
        gcloud compute ssh --project $PROJECT_ID --zone $ZONE ubuntu-postgres-vm

        # Once inside:
        chmod +x verify_db.sh
        sudo ./verify_db.sh postgres
        ```

The script will output SUCCESS or FAILURE for each check (service status, data disk mount, database connection).

Disk Layout & Mounts

*   `/dev/sda` (OS Disk): Mounted at `/`
*   `/dev/sdb` (Data Disk): Mounted at `/var/lib/mysql_data` (MySQL) or `/var/lib/postgresql_data` (PostgreSQL)
*   `/dev/sdc` (Backup Disk): Mounted at `/var/lib/mysql_backups` (MySQL) or `/var/lib/postgresql_backups` (PostgreSQL)

All disks are Terraform-managed and will be deleted upon destroy.

## Cleaning Up / Destroying Resources

When you are finished with the test environment, you can destroy all the resources created by Terraform using the following command in the root directory of this repository:

```bash
terraform destroy -auto-approve
```

This will de-provision the VMs, disks, network resources, etc.

## Notes

*   The default database password is configured in `terraform.tfvars` via the `db_password` variable. **CHANGE THIS IN A PRODUCTION ENVIRONMENT.**
    *   Default: `MyS@L_1nSt@nce!P@$$wOrd0`
*   Firewall rules only allow SSH access from Google's IAP ranges. Database ports (3306, 5432) are not exposed externally.
*   The VMs use `e2-medium` machine types by default. Adjust as needed in `variables.tf` or `terraform.tfvars`.
*   Each VM is configured with three persistent disks: one for the OS, one for the database binaries/data, and one for backups. The VMs do not have external IP addresses and rely on Cloud NAT for outbound internet access.
