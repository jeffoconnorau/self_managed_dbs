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
  description = "The machine type for the VMs."
  type        = string
  default     = "e2-medium"
}

variable "rocky_vm_name" {
  description = "The name for the Rocky Linux VM."
  type        = string
  default     = "rocky-mysql-vm"
}

variable "ubuntu_vm_name" {
  description = "The name for the Ubuntu VM."
  type        = string
  default     = "ubuntu-postgres-vm"
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

variable "backup_retention_days" {
  description = "Number of days to retain backups (deprecated, use specific full/log retention)."
  type        = number
  default     = 3
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
