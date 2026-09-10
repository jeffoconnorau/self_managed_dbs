terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.20.0"
    }
  }
}

provider "google" {

  project = var.project_id
  region  = var.region
  zone    = var.zone
}

locals {
  mysql_images = {
    "rocky-linux-9" = "rocky-linux-cloud/rocky-linux-9"
    "rhel-9"        = "rhel-cloud/rhel-9"
    "rhel-8"        = "rhel-cloud/rhel-8"
    "ubuntu-2204"   = "ubuntu-os-cloud/ubuntu-2204-lts"
    "debian-12"     = "debian-cloud/debian-12"
  }
  selected_mysql_image = lookup(local.mysql_images, var.mysql_linux_flavor, "rocky-linux-cloud/rocky-linux-9")
  mysql_vm_name        = var.mysql_vm_name != "rocky-mysql-vm" ? var.mysql_vm_name : var.rocky_vm_name

  postgres_images = {
    "ubuntu-2204"   = "ubuntu-os-cloud/ubuntu-2204-lts"
    "debian-12"     = "debian-cloud/debian-12"
    "rocky-linux-9" = "rocky-linux-cloud/rocky-linux-9"
    "rhel-9"        = "rhel-cloud/rhel-9"
  }
  selected_postgres_image = lookup(local.postgres_images, var.postgres_linux_flavor, "ubuntu-os-cloud/ubuntu-2204-lts")
  postgres_vm_name        = var.postgres_vm_name != "ubuntu-postgres-vm" ? var.postgres_vm_name : var.ubuntu_vm_name

  db2_images = {
    "rocky-linux-9" = "rocky-linux-cloud/rocky-linux-9"
    "rhel-9"        = "rhel-cloud/rhel-9"
    "rhel-8"        = "rhel-cloud/rhel-8"
    "sles-15"       = "suse-cloud/sles-15"
    "ubuntu-2204"   = "ubuntu-os-cloud/ubuntu-2204-lts"
  }
  selected_db2_image = lookup(local.db2_images, var.db2_linux_flavor, "ubuntu-os-cloud/ubuntu-2204-lts")
}

resource "google_compute_network" "vpc_network" {
  name                    = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name                     = var.subnetwork_name
  ip_cidr_range            = var.subnetwork_ip_cidr_range
  network                  = google_compute_network.vpc_network.id
  region                   = var.region
  private_ip_google_access = true
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "${var.network_name}-allow-ssh"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh"]
}

# --- MySQL VM (Configurable Linux Flavour) ---
resource "google_compute_instance" "rocky_mysql_vm" {
  count        = var.enable_mysql_vm ? 1 : 0
  name         = local.mysql_vm_name
  machine_type = coalesce(var.mysql_machine_type, var.vm_machine_type)
  zone         = var.zone
  tags         = ["ssh"]

  boot_disk {
    auto_delete = true
    initialize_params {
      image = local.selected_mysql_image
      size  = var.os_disk_size_gb
    }
  }

  attached_disk {
    source      = google_compute_disk.rocky_data_disk[0].id
    device_name = "data-disk"
  }

  attached_disk {
    source      = google_compute_disk.rocky_backup_disk[0].id
    device_name = "backup-disk"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  metadata = {
    MYSQL_DB_NAME               = var.mysql_db_name
    DB_PASSWORD                 = var.db_password
    BACKUP_RETENTION_DAYS_FULL  = var.backup_retention_days_full
    BACKUP_RETENTION_DAYS_LOG   = var.backup_retention_days_log
    FULL_BACKUP_INTERVAL_HOURS  = var.full_backup_interval_hours
    LOG_BACKUP_INTERVAL_MINUTES = var.log_backup_interval_minutes
    FULL_BACKUP_TIME            = var.full_backup_time
    BACKUP_SCRIPT_CONTENT       = file("${path.module}/scripts/db_backup.sh")
    BACKUP_DASHBOARD_CONTENT    = file("${path.module}/scripts/backup_dashboard.py")
    VERIFY_DB_CONTENT           = file("${path.module}/scripts/verify_db.sh")
    REPORT_CRON_SCHEDULE        = var.report_cron_schedule
    REPORT_RECIPIENTS           = var.report_recipients
    SMTP_HOST                   = var.smtp_host
    SMTP_PORT                   = var.smtp_port
  }
  metadata_startup_script = file("${path.module}/scripts/mysql_setup.sh")

  shielded_instance_config {
    enable_secure_boot = true
  }

  service_account {
    scopes = ["cloud-platform"]
  }

}

resource "google_compute_disk" "rocky_data_disk" {
  count = var.enable_mysql_vm ? 1 : 0
  name  = "${local.mysql_vm_name}-data"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.disk_size_gb
}

resource "google_compute_disk" "rocky_backup_disk" {
  count = var.enable_mysql_vm ? 1 : 0
  name  = "${local.mysql_vm_name}-backup"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.disk_size_gb
}

# --- PostgreSQL VM (Configurable Linux Flavour) ---
resource "google_compute_instance" "ubuntu_postgres_vm" {
  count        = var.enable_postgres_vm ? 1 : 0
  name         = local.postgres_vm_name
  machine_type = coalesce(var.postgres_machine_type, var.vm_machine_type)
  zone         = var.zone
  tags         = ["ssh"]

  boot_disk {
    auto_delete = true
    initialize_params {
      image = local.selected_postgres_image
      size  = var.os_disk_size_gb
    }
  }

  attached_disk {
    source      = google_compute_disk.ubuntu_data_disk[0].id
    device_name = "data-disk"
  }

  attached_disk {
    source      = google_compute_disk.ubuntu_backup_disk[0].id
    device_name = "backup-disk"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  metadata = {
    POSTGRES_DB_NAME            = var.postgres_db_name
    DB_PASSWORD                 = var.db_password
    BACKUP_RETENTION_DAYS_FULL  = var.backup_retention_days_full
    BACKUP_RETENTION_DAYS_LOG   = var.backup_retention_days_log
    FULL_BACKUP_INTERVAL_HOURS  = var.full_backup_interval_hours
    LOG_BACKUP_INTERVAL_MINUTES = var.log_backup_interval_minutes
    FULL_BACKUP_TIME            = var.full_backup_time
    BACKUP_SCRIPT_CONTENT       = file("${path.module}/scripts/db_backup.sh")
    BACKUP_DASHBOARD_CONTENT    = file("${path.module}/scripts/backup_dashboard.py")
    VERIFY_DB_CONTENT           = file("${path.module}/scripts/verify_db.sh")
    REPORT_CRON_SCHEDULE        = var.report_cron_schedule
    REPORT_RECIPIENTS           = var.report_recipients
    SMTP_HOST                   = var.smtp_host
    SMTP_PORT                   = var.smtp_port
  }
  metadata_startup_script = file("${path.module}/scripts/postgres_setup.sh")

  shielded_instance_config {
    enable_secure_boot = true
  }

  service_account {
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_disk" "ubuntu_data_disk" {
  count = var.enable_postgres_vm ? 1 : 0
  name  = "${local.postgres_vm_name}-data"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.disk_size_gb
}

resource "google_compute_disk" "ubuntu_backup_disk" {
  count = var.enable_postgres_vm ? 1 : 0
  name  = "${local.postgres_vm_name}-backup"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.disk_size_gb
}

# --- IBM Db2 VM on Configurable Linux Flavour ---
resource "google_compute_instance" "db2_vm" {
  count        = var.enable_db2_vm ? 1 : 0
  name         = var.db2_vm_name
  machine_type = coalesce(var.db2_machine_type, var.vm_machine_type)
  zone         = var.zone
  tags         = ["ssh"]

  boot_disk {
    auto_delete = true
    initialize_params {
      image = local.selected_db2_image
      size  = var.os_disk_size_gb
    }
  }

  attached_disk {
    source      = google_compute_disk.db2_data_disk[0].id
    device_name = "data-disk"
  }

  attached_disk {
    source      = google_compute_disk.db2_backup_disk[0].id
    device_name = "backup-disk"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  metadata = {
    DB2_DB_NAME                 = var.db2_db_name
    DB_PASSWORD                 = var.db_password
    DB2_INSTANCE_USER           = var.db2_instance_user
    DB2_INSTALLER_URL           = var.db2_installer_url
    BACKUP_RETENTION_DAYS_FULL  = var.backup_retention_days_full
    BACKUP_RETENTION_DAYS_LOG   = var.backup_retention_days_log
    FULL_BACKUP_INTERVAL_HOURS  = var.full_backup_interval_hours
    LOG_BACKUP_INTERVAL_MINUTES = var.log_backup_interval_minutes
    FULL_BACKUP_TIME            = var.full_backup_time
    BACKUP_SCRIPT_CONTENT       = file("${path.module}/scripts/db_backup.sh")
    BACKUP_DASHBOARD_CONTENT    = file("${path.module}/scripts/backup_dashboard.py")
    VERIFY_DB_CONTENT           = file("${path.module}/scripts/verify_db.sh")
    REPORT_CRON_SCHEDULE        = var.report_cron_schedule
    REPORT_RECIPIENTS           = var.report_recipients
    SMTP_HOST                   = var.smtp_host
    SMTP_PORT                   = var.smtp_port
  }
  metadata_startup_script = file("${path.module}/scripts/db2_setup.sh")

  shielded_instance_config {
    enable_secure_boot = true
  }

  service_account {
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_disk" "db2_data_disk" {
  count = var.enable_db2_vm ? 1 : 0
  name  = "${var.db2_vm_name}-data"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.disk_size_gb
}

resource "google_compute_disk" "db2_backup_disk" {
  count = var.enable_db2_vm ? 1 : 0
  name  = "${var.db2_vm_name}-backup"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.disk_size_gb
}

# --- Cloud NAT for Internet Access ---
resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  network = google_compute_network.vpc_network.name
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
  nat_ip_allocate_option           = "AUTO_ONLY"
  tcp_established_idle_timeout_sec = 1200
}
