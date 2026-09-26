variable "project" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project))
    error_message = "Supply an explicit Google project ID."
  }
}
variable "zone" {
  type = string
  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+-[a-z]$", var.zone))
    error_message = "Supply an explicit zone, not a region."
  }
}
variable "owner" {
  type = string
  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,9}[a-z0-9])?$", var.owner))
    error_message = "Owner must be a lowercase label, 1–11 characters."
  }
}
variable "run" {
  type = string
  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,9}[a-z0-9])?$", var.run))
    error_message = "Run must be a lowercase label, 1–11 characters."
  }
}
variable "billing_owner" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9_-]{0,62}$", var.billing_owner))
    error_message = "Provide the accountable billing owner as a label, not an inferred billing account."
  }
}
variable "admin_cidr" {
  type        = string
  description = "Narrow private RFC1918 source CIDR of an existing authenticated admin route (VPN/tunnel)."
  validation {
    condition = can(cidrnetmask(var.admin_cidr)) && can(regex("/(2[4-9]|3[0-2])$", var.admin_cidr)) && (
      can(regex("^10\\.", var.admin_cidr)) || can(regex("^192\\.168\\.", var.admin_cidr)) ||
      can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.", var.admin_cidr))
    )
    error_message = "Admin CIDR must be RFC1918 IPv4, /24 or narrower. No public API endpoint is enabled."
  }
}
variable "spot" {
  type    = bool
  default = false
}
variable "paused" {
  type    = bool
  default = false
}

variable "app" { type = string }
variable "environment" { type = string }
variable "state_bucket" { type = string }
