variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  description = "GCP region. Default decision: europe-west1 / Belgium."
  default     = "europe-west1"
}

variable "zone" {
  type        = string
  description = "GCP zone."
  default     = "europe-west1-b"
}

variable "environment" {
  type        = string
  description = "Environment label, e.g. local, ci, demo."
  default     = "local"
}

variable "run_id" {
  type        = string
  description = "Run identifier used in names and labels."
  default     = "local"
}

variable "repo_label" {
  type        = string
  default     = "superapp"
  description = "Repository/application label."
}

variable "machine_type" {
  type        = string
  default     = "e2-standard-2"
  description = "Compute Engine machine type."
}

variable "image_project" {
  type        = string
  default     = "fedora-cloud"
  description = "Image project for boot disk."
}

variable "image_family" {
  type        = string
  default     = "fedora-cloud-43-x86-64"
  description = "Image family for boot disk."
}

variable "boot_disk_size_gb" {
  type        = number
  default     = 30
  description = "Boot disk size in GiB."
}

variable "boot_disk_type" {
  type        = string
  default     = "pd-balanced"
  description = "Boot disk type."
}

variable "demo_port" {
  type        = number
  default     = 8080
  description = "HTTP demo/smoke-test port."
}

variable "allow_ssh_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR allowed for SSH during local/demo testing. Tighten later or use IAP."
}

variable "allow_http_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR allowed for the temporary demo HTTP endpoint."
}

variable "create_firewall_rules" {
  type        = bool
  default     = false
  description = "Create temporary SSH/HTTP firewall rules. Requires compute.firewalls.create and compute.networks.updatePolicy. Default false so least-privileged VM creation works with pre-existing/default firewall rules."
}
