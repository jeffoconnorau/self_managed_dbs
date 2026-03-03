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
