terraform {
  backend "gcs" {}
  required_version = "= 1.12.3"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "= 6.49.0"
    }
  }
}

provider "google" {
  project = var.project
  region  = local.region
  zone    = var.zone
}

locals {
  region = replace(var.zone, "/-[a-z]$/", "")
  name   = "${var.app}-${var.environment}-${var.owner}-${var.run}"
  labels = { owner = var.owner, run = var.run, managed_by = "opentofu", billing_owner = var.billing_owner }
  apis   = toset(["compute.googleapis.com", "container.googleapis.com", "iam.googleapis.com", "logging.googleapis.com", "monitoring.googleapis.com"])
}

resource "google_project_service" "required" {
  for_each                   = local.apis
  project                    = var.project
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

resource "google_compute_network" "demo" {
  project                 = var.project
  name                    = local.name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.required]
}

resource "google_compute_subnetwork" "demo" {
  project                  = var.project
  name                     = local.name
  region                   = local.region
  network                  = google_compute_network.demo.id
  ip_cidr_range            = "10.40.0.0/24"
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.44.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.48.0.0/20"
  }
}

# Explicit outbound access for public image pulls; no inbound public node IPs.
resource "google_compute_router" "demo" {
  project = var.project
  name    = local.name
  region  = local.region
  network = google_compute_network.demo.id
}

resource "google_compute_router_nat" "demo" {
  project                            = var.project
  name                               = local.name
  router                             = google_compute_router.demo.name
  region                             = local.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.demo.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

resource "google_service_account" "node" {
  project      = var.project
  account_id   = local.name
  display_name = "GKE demo nodes ${var.owner}/${var.run}"
  depends_on   = [google_project_service.required]
}

# GKE's minimum node role includes logging/monitoring, not Editor or workload access.
resource "google_project_iam_member" "node" {
  project    = var.project
  role       = "roles/container.defaultNodeServiceAccount"
  member     = "serviceAccount:${local.name}@${var.project}.iam.gserviceaccount.com"
  depends_on = [google_service_account.node]
}

resource "google_container_cluster" "demo" {
  project                  = var.project
  name                     = local.name
  location                 = var.zone
  network                  = google_compute_network.demo.id
  subnetwork               = google_compute_subnetwork.demo.id
  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false # teardown is guarded by lifecycle.py, not an untracked toggle
  resource_labels          = local.labels
  datapath_provider        = "ADVANCED_DATAPATH"
  networking_mode          = "VPC_NATIVE"
  enable_shielded_nodes    = true
  release_channel { channel = "REGULAR" }
  workload_identity_config { workload_pool = "${var.project}.svc.id.goog" }
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }
  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.admin_cidr
      display_name = "approved-private-admin"
    }
    private_endpoint_enforcement_enabled = true
  }
  logging_config { enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"] }
  monitoring_config { enable_components = ["SYSTEM_COMPONENTS"] }
  # Also constrain the short-lived bootstrap default pool.
  node_config {
    machine_type    = "e2-standard-2"
    disk_size_gb    = 30
    disk_type       = "pd-balanced"
    service_account = google_service_account.node.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    metadata        = { disable-legacy-endpoints = "true" }
    workload_metadata_config { mode = "GKE_METADATA" }
  }
  depends_on = [google_project_iam_member.node]
}

resource "google_container_node_pool" "demo" {
  project    = var.project
  name       = local.name
  location   = var.zone
  cluster    = google_container_cluster.demo.name
  node_count = var.paused ? 0 : 1
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  upgrade_settings {
    max_surge       = 0
    max_unavailable = 1
  }
  node_config {
    machine_type    = "e2-standard-2"
    disk_size_gb    = 30
    disk_type       = "pd-balanced"
    spot            = var.spot
    service_account = google_service_account.node.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = local.labels
    metadata        = { disable-legacy-endpoints = "true" }
    workload_metadata_config { mode = "GKE_METADATA" }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }
  depends_on = [google_compute_router_nat.demo]
}

output "cluster_name" { value = google_container_cluster.demo.name }
output "private_endpoint" {
  value     = google_container_cluster.demo.private_cluster_config[0].private_endpoint
  sensitive = true
}
output "node_service_account" { value = google_service_account.node.email }
output "desired_nodes" { value = var.paused ? 0 : 1 }

output "deployment_config" {
  value = { app = var.app, environment = var.environment, state_bucket = var.state_bucket, project = var.project, zone = var.zone, owner = var.owner, run = var.run, billing_owner = var.billing_owner, admin_cidr = var.admin_cidr, spot = var.spot }
}
