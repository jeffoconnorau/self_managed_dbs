# Self-Managed Databases on GCP with Terraform

This repository contains Terraform code to provision two Google Compute Engine VMs, one running Rocky Linux with MySQL and the other running Ubuntu with PostgreSQL. Each VM is configured with three persistent disks: one for the OS, one for the database binaries/data, and one for backups.

## Prerequisites

1.  **Google Cloud SDK:** Install and initialize `gcloud`.
2.  **Terraform:** Install Terraform CLI.
3.  **GCP Project:** Have a GCP project with billing enabled.
4.  **Permissions:** Ensure you have necessary permissions to create VPCs, Subnets, Firewall Rules, Compute Instances, and Disks.

## Directory Structure

```
.
├── main.tf             # Main Terraform configuration
├── variables.tf        # Variable declarations
├── terraform.tfvars    # Variable values (YOU NEED TO EDIT THIS)
├── outputs.tf          # Outputs
├── scripts/
│   ├── mysql_setup.sh  # Startup script for Rocky/MySQL
│   └── postgres_setup.sh # Startup script for Ubuntu/PostgreSQL
└── README.md           # This file
```

## Configuration Steps

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/jeffoconnorau/self_managed_dbs
    cd self_managed_dbs
    ```

2.  **Configure Variables:**
    Edit `terraform.tfvars` and replace `"Your-GCP-Project-ID"` with your actual GCP Project ID:
    ```terraform
    project_id = "Your-GCP-Project-ID"
    region     = "us-central1"
    zone       = "us-central1-a"
    ```

3.  **Initialize Terraform:**
    ```bash
    terraform init
    ```

4.  **Plan the deployment:**
    ```bash
    terraform plan
    ```
    Review the plan to ensure it's going to create the resources as expected.

5.  **Apply the configuration:**
    ```bash
    terraform apply -auto-approve
    ```
    This will provision all the resources. The startup scripts will run on the first boot of each VM to install and configure the databases.

## Connecting to the VMs

Once applied, Terraform will output the external IP addresses and SSH commands for each VM.

*   **To SSH into the Rocky/MySQL VM:**
    ```bash
    # Command will be shown in terraform output 'ssh_command_rocky'
    # Example:
    # gcloud compute ssh --project Your-GCP-Project-ID --zone us-central1-a rocky-mysql-vm
    ```

*   **To SSH into the Ubuntu/PostgreSQL VM:**
    ```bash
    # Command will be shown in terraform output 'ssh_command_ubuntu'
    # Example:
    # gcloud compute ssh --project Your-GCP-Project-ID --zone us-central1-a ubuntu-postgres-vm
    ```

## Verifying Database Installations

A verification script `scripts/verify_db.sh` is included. You can run this on each VM after SSHing:

1.  **Copy the script to the VM:**

    *   For Rocky/MySQL:
        ```bash
        gcloud compute scp scripts/verify_db.sh rocky-mysql-vm:~ --project argo-svc-dev-3 --zone asia-southeast1-a
        ```

    *   For Ubuntu/PostgreSQL:
        ```bash
        gcloud compute scp scripts/verify_db.sh ubuntu-postgres-vm:~ --project argo-svc-dev-3 --zone asia-southeast1-a
        ```

2.  **SSH into the VM and Run the script:**

    *   **Rocky/MySQL VM:**
        ```bash
        # SSH first using the command from terraform output 'ssh_command_rocky'
        gcloud compute ssh --project argo-svc-dev-3 --zone asia-southeast1-a rocky-mysql-vm
        
        # Once inside:
        chmod +x verify_db.sh
        sudo ./verify_db.sh mysql
        ```

    *   **Ubuntu/PostgreSQL VM:**
        ```bash
        # SSH first using the command from terraform output 'ssh_command_ubuntu'
        gcloud compute ssh --project argo-svc-dev-3 --zone asia-southeast1-a ubuntu-postgres-vm
        
        # Once inside:
        chmod +x verify_db.sh
        sudo ./verify_db.sh postgres
        ```

The script will output SUCCESS or FAILURE for each check (service status, data disk mount, database connection).

## Disk Layout

*   `/dev/sda`: Operating System (auto-deleted with VM by default)
*   `/dev/sdb`: Data disk (deleted as it's a Terraform-managed resource)
*   `/dev/sdc`: Backup disk (deleted as it's a Terraform-managed resource)

## Disk Mounts

*   `/dev/sda`: Operating System
*   `/dev/sdb`: Mounted at `/var/lib/mysql_data` (MySQL) or `/var/lib/postgresql_data` (PostgreSQL)
*   `/dev/sdc`: Mounted at `/var/lib/mysql_backups` (MySQL) or `/var/lib/postgresql_backups` (PostgreSQL)

## Cleaning Up

To destroy all resources created by Terraform:

```bash
terraform destroy -auto-approve
```

## Notes

*   The default database passwords are set to `YourSecurePassword1!`. **CHANGE THESE IN A PRODUCTION ENVIRONMENT.**
*   Firewall rules only allow SSH access. You may need to add rules for database ports (3306 for MySQL, 5432 for PostgreSQL) if you need to connect from outside the VPC.
*   The VMs are using `e2-small` machine types and standard persistent disks to minimize costs. Adjust as needed in `variables.tf` or `terraform.tfvars`.
```
