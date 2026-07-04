locals {
  safe_run_id = substr(replace(lower(var.run_id), "/[^a-z0-9-]/", "-"), 0, 24)
  name        = "hermes-demo-${local.safe_run_id}"
  labels = {
    owner       = "hermes"
    purpose     = "ci-demo"
    repo        = var.repo_label
    run_id      = local.safe_run_id
    environment = var.environment
  }

  ssh_metadata = var.add_ssh_key ? {
    ssh-keys = "${var.ssh_user}:${trimspace(file(pathexpand(var.ssh_public_key_path)))}"
  } : {}
}

data "google_compute_image" "os" {
  family  = var.image_family
  project = var.image_project
}

resource "google_compute_firewall" "demo_http" {
  count       = var.create_firewall_rules ? 1 : 0
  name        = "${local.name}-http"
  network     = "default"
  description = "Temporary demo HTTP access for ${local.name}"

  allow {
    protocol = "tcp"
    ports    = [tostring(var.demo_port)]
  }

  source_ranges = [var.allow_http_cidr]
  target_tags   = [local.name]
}

resource "google_compute_firewall" "demo_ssh" {
  count       = var.create_firewall_rules ? 1 : 0
  name        = "${local.name}-ssh"
  network     = "default"
  description = "Temporary SSH access for ${local.name}"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.allow_ssh_cidr]
  target_tags   = [local.name]
}

resource "google_compute_instance" "demo" {
  name         = local.name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [local.name]
  labels       = local.labels

  boot_disk {
    auto_delete = true
    initialize_params {
      image  = data.google_compute_image.os.self_link
      size   = var.boot_disk_size_gb
      type   = var.boot_disk_type
      labels = local.labels
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata = local.ssh_metadata

  metadata_startup_script = templatefile("${path.module}/startup-script.sh.tftpl", {
    demo_port   = var.demo_port
    region      = var.region
    zone        = var.zone
    environment = var.environment
    run_id      = local.safe_run_id
  })

  scheduling {
    automatic_restart           = false
    on_host_maintenance         = "MIGRATE"
    provisioning_model          = "STANDARD"
    instance_termination_action = var.auto_delete_after_duration ? "DELETE" : null

    dynamic "max_run_duration" {
      for_each = var.auto_delete_after_duration ? [1] : []
      content {
        seconds = var.max_run_duration_seconds
        nanos   = 0
      }
    }
  }
}
