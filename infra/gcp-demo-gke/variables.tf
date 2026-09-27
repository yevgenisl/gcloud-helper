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
  description = "Canonical admin source: RFC1918 /24 or narrower privately; globally routable /32 publicly."
  validation {
    condition = try(cidrnetmask(var.admin_cidr) != "" && "${cidrhost(var.admin_cidr, 0)}/${split("/", var.admin_cidr)[1]}" == var.admin_cidr && (
      var.public_endpoint ? (
        endswith(var.admin_cidr, "/32") && !anytrue([for blocked in [
          "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
          "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16",
          "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4"
        ] : cidrcontains(blocked, cidrhost(var.admin_cidr, 0))])
        ) : (
        tonumber(split("/", var.admin_cidr)[1]) >= 24 && anytrue([
          for private in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"] : cidrcontains(private, cidrhost(var.admin_cidr, 0))
        ])
      )
    ), false)
    error_message = "Admin CIDR must be canonical: RFC1918 /24 or narrower privately, globally routable IPv4 /32 publicly (no special-use addresses)."
  }
}
variable "public_endpoint" {
  type        = bool
  default     = false
  description = "Explicit opt-in to public control-plane access only; workers remain private."
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
