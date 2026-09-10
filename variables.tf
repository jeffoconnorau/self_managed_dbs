variable "project_id" {
  description = "The GCP project ID."
  type        = string
}

variable "region" {
  description = "The GCP region for the resources."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone for the resources."
  type        = string
  default     = "us-central1-a"
}

variable "network_name" {
  description = "The name of the VPC network."
  type        = string
  default     = "self-managed-dbs-vpc"
}

variable "subnetwork_name" {
  description = "The name of the subnetwork."
  type        = string
  default     = "self-managed-dbs-subnet"
}

variable "subnetwork_ip_cidr_range" {
  description = "The IP CIDR range for the subnetwork."
  type        = string
  default     = "10.128.0.0/20"
}

variable "vm_machine_type" {
  description = "The default machine type for the database VMs (minimum 4 vCPUs recommended for enterprise database workloads, e.g., e2-standard-4)."
  type        = string
  default     = "e2-standard-4"
}

variable "mysql_machine_type" {
  description = "Optional machine type override for the MySQL VM. Defaults to var.vm_machine_type."
  type        = string
  default     = null
}

variable "postgres_machine_type" {
  description = "Optional machine type override for the PostgreSQL VM. Defaults to var.vm_machine_type."
  type        = string
  default     = null
}

variable "db2_machine_type" {
  description = "Optional machine type override for the Db2 VM. Defaults to var.vm_machine_type."
  type        = string
  default     = null
}

# --- MySQL Configuration Variables ---
variable "enable_mysql_vm" {
  description = "Enable or disable provisioning the MySQL VM."
  type        = bool
  default     = true
}

variable "mysql_vm_name" {
  description = "The name for the MySQL VM."
  type        = string
  default     = "rocky-mysql-vm"
}

variable "rocky_vm_name" {
  description = "Legacy variable alias for the MySQL VM name."
  type        = string
  default     = "rocky-mysql-vm"
}

variable "mysql_linux_flavor" {
  description = "Linux distribution for MySQL VM. Options: 'rocky-linux-9' (default), 'rhel-9', 'rhel-8', 'ubuntu-2204', 'debian-12'."
  type        = string
  default     = "rocky-linux-9"
}

# --- PostgreSQL Configuration Variables ---
variable "enable_postgres_vm" {
  description = "Enable or disable provisioning the PostgreSQL VM."
  type        = bool
  default     = true
}

variable "postgres_vm_name" {
  description = "The name for the PostgreSQL VM."
  type        = string
  default     = "ubuntu-postgres-vm"
}

variable "ubuntu_vm_name" {
  description = "Legacy variable alias for the PostgreSQL VM name."
  type        = string
  default     = "ubuntu-postgres-vm"
}

variable "postgres_linux_flavor" {
  description = "Linux distribution for PostgreSQL VM. Options: 'ubuntu-2204' (default), 'debian-12', 'rocky-linux-9', 'rhel-9'."
  type        = string
  default     = "ubuntu-2204"
}

variable "disk_size_gb" {
  description = "The size of the data and backup disks in GB."
  type        = number
  default     = 20
}

variable "os_disk_size_gb" {
  description = "The size of the OS disk in GB."
  type        = number
  default     = 20
}

variable "mysql_db_name" {
  description = "The default database name to create in MySQL."
  type        = string
  default     = "db1"
}

variable "postgres_db_name" {
  description = "The default database name to create in PostgreSQL."
  type        = string
  default     = "db1"
}

variable "db_password" {
  description = "The password for the database root/postgres user."
  type        = string
  sensitive   = true
}


variable "backup_retention_days_full" {
  description = "Number of days to retain full backups."
  type        = number
  default     = 3
}

variable "backup_retention_days_log" {
  description = "Number of days to retain log backups."
  type        = number
  default     = 3
}

variable "full_backup_interval_hours" {
  description = "Frequency of full backups in hours."
  type        = number
  default     = 24
}

variable "log_backup_interval_minutes" {
  description = "Frequency of log backups in minutes."
  type        = number
  default     = 15
}

variable "full_backup_time" {
  description = "Specific time to run full backups (HH:MM) in UTC. If set, a dedicated cron job is created."
  type        = string
  default     = "02:00"
}

# --- IBM Db2 Configuration Variables ---
variable "enable_db2_vm" {
  description = "Enable or disable provisioning the IBM Db2 VM."
  type        = bool
  default     = true
}

variable "db2_vm_name" {
  description = "The name for the IBM Db2 VM."
  type        = string
  default     = "db2-backup-vm"
}

variable "db2_linux_flavor" {
  description = "Linux distribution for IBM Db2. IBM officially validates specific enterprise Linux OS distributions. Options: 'ubuntu-2204' (default), 'rocky-linux-9', 'rhel-9', 'rhel-8', 'sles-15'."
  type        = string
  default     = "ubuntu-2204"
}

variable "db2_db_name" {
  description = "The default database name to create in IBM Db2."
  type        = string
  default     = "db1"
}

variable "db2_instance_user" {
  description = "The instance owner user for IBM Db2."
  type        = string
  default     = "db2inst1"
}

variable "db2_installer_url" {
  description = "Optional URL (gs:// or https://) to an IBM Db2 installation archive (e.g. gs://your-bucket/v11.5.8_linuxx64_server_dec.tar.gz)."
  type        = string
  default     = ""
}

# --- Backup Dashboard & Daily Email Reporting Variables ---
variable "report_cron_schedule" {
  description = "Cron schedule expression for the daily backup health dashboard report (default: daily at 08:00 UTC)."
  type        = string
  default     = "0 8 * * *"
}

variable "report_recipients" {
  description = "Comma-separated list of email addresses to receive the daily backup health dashboard report."
  type        = string
  default     = ""
}

variable "smtp_host" {
  description = "SMTP relay server host for mailing the daily report (e.g., smtp.sendgrid.net or smtp.gmail.com). If empty, falls back to local MTA."
  type        = string
  default     = ""
}

variable "smtp_port" {
  description = "SMTP relay server port (default: 587)."
  type        = number
  default     = 587
}

variable "smtp_user" {
  description = "Optional SMTP authentication username."
  type        = string
  default     = ""
}

variable "smtp_password" {
  description = "Optional SMTP authentication password."
  type        = string
  default     = ""
  sensitive   = true
}
