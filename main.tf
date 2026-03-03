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

resource "google_compute_network" "vpc_network" {
  name                    = var.network_name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = var.subnetwork_name
  ip_cidr_range = var.subnetwork_ip_cidr_range
  network       = google_compute_network.vpc_network.id
  region        = var.region
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

# --- Rocky Linux VM for MySQL ---
resource "google_compute_instance" "rocky_mysql_vm" {
  name         = var.rocky_vm_name
  machine_type = var.vm_machine_type
  zone         = var.zone
  tags         = ["ssh"]

  boot_disk {
    auto_delete = true
    initialize_params {
      image = "rocky-linux-cloud/rocky-linux-9"
      size  = var.os_disk_size_gb
    }
  }

  attached_disk {
    source      = google_compute_disk.rocky_data_disk.id
    device_name = "data-disk"
  }

  attached_disk {
    source      = google_compute_disk.rocky_backup_disk.id
    device_name = "backup-disk"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  metadata = {
    MYSQL_DB_NAME = var.mysql_db_name
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
  name  = "${var.rocky_vm_name}-data"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.disk_size_gb
}

resource "google_compute_disk" "rocky_backup_disk" {
  name  = "${var.rocky_vm_name}-backup"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.disk_size_gb
}

# --- Ubuntu VM for PostgreSQL ---
resource "google_compute_instance" "ubuntu_postgres_vm" {
  name         = var.ubuntu_vm_name
  machine_type = var.vm_machine_type
  zone         = var.zone
  tags         = ["ssh"]

  boot_disk {
    auto_delete = true
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = var.os_disk_size_gb
    }
  }

  attached_disk {
    source      = google_compute_disk.ubuntu_data_disk.id
    device_name = "data-disk"
  }

  attached_disk {
    source      = google_compute_disk.ubuntu_backup_disk.id
    device_name = "backup-disk"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
  }

  metadata = {
    POSTGRES_DB_NAME = var.postgres_db_name
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
  name  = "${var.ubuntu_vm_name}-data"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.disk_size_gb
}

resource "google_compute_disk" "ubuntu_backup_disk" {
  name  = "${var.ubuntu_vm_name}-backup"
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
  nat_ip_allocate_option             = "AUTO_ONLY"
  tcp_established_idle_timeout_sec = 1200
}
