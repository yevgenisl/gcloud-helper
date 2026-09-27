mock_provider "google" {}
# 8.8.8.8 is a validation-only fixture, never an operator address or deployment input.
run "public_admin_private_workers" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "8.8.8.8/32"
  }
  assert {
    condition     = !google_container_cluster.demo.private_cluster_config[0].enable_private_endpoint && google_container_cluster.demo.private_cluster_config[0].enable_private_nodes
    error_message = "Only the control plane may be public; workers must stay private."
  }
  assert {
    condition     = length(google_container_cluster.demo.master_authorized_networks_config[0].cidr_blocks) == 1 && one(google_container_cluster.demo.master_authorized_networks_config[0].cidr_blocks).cidr_block == var.admin_cidr && !google_container_cluster.demo.master_authorized_networks_config[0].gcp_public_cidrs_access_enabled
    error_message = "Only the explicit administrator /32 may be authorized."
  }
  assert {
    condition     = output.deployment_config.public_endpoint && output.deployment_config.admin_cidr == var.admin_cidr
    error_message = "Remote configuration must retain the exact endpoint mode and administrator CIDR."
  }
}

run "reject_public_0" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "0.0.0.0/0"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_1" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "8.8.8.0/24"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_2" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "8.8.8.8/24"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_3" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "8.8.8.8"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_4" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "10.1.2.3/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_5" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "172.16.0.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_6" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "192.168.0.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_7" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "127.0.0.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_8" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "169.254.1.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_9" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "100.64.0.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_10" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "192.0.0.9/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_11" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "192.88.99.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_12" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "192.0.2.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_13" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "198.18.0.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_14" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "198.51.100.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_15" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "203.0.113.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_16" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "224.0.0.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_17" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "240.0.0.1/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_18" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "255.255.255.255/32"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_public_19" {
  command = plan
  variables {
    public_endpoint = true
    admin_cidr      = "::1/128"
  }
  expect_failures = [var.admin_cidr]
}

run "reject_private_noncanonical" {
  command = plan
  variables { admin_cidr = "10.40.0.5/24" }
  expect_failures = [var.admin_cidr]
}


variables {
  app           = "ai"
  environment   = "demo"
  state_bucket  = "test-state-bucket"
  project       = "test-project"
  zone          = "us-central1-a"
  owner         = "alice"
  run           = "demo"
  billing_owner = "team"
  admin_cidr    = "10.40.0.5/32"
}

run "one_private_node" {
  command = plan
  assert {
    condition     = google_container_node_pool.demo.node_count == 1 && google_container_node_pool.demo.node_config[0].machine_type == "e2-standard-2" && google_container_node_pool.demo.node_config[0].disk_size_gb == 30
    error_message = "Demo must have exactly one e2-standard-2 with a 30GB disk."
  }
  assert {
    condition     = google_container_cluster.demo.private_cluster_config[0].enable_private_endpoint && google_container_cluster.demo.private_cluster_config[0].enable_private_nodes && google_container_cluster.demo.master_authorized_networks_config[0].private_endpoint_enforcement_enabled
    error_message = "Workers and control plane must stay private and admin CIDR enforced."
  }
  assert {
    condition     = google_container_cluster.demo.datapath_provider == "ADVANCED_DATAPATH" && google_container_cluster.demo.release_channel[0].channel == "REGULAR" && google_container_cluster.demo.workload_identity_config[0].workload_pool == "test-project.svc.id.goog"
    error_message = "Dataplane V2, regular channel and Workload Identity are mandatory."
  }
  assert {
    condition     = google_project_iam_member.node.role == "roles/container.defaultNodeServiceAccount" && alltrue([for api in google_project_service.required : !api.disable_on_destroy])
    error_message = "Use minimum node role and never disable shared APIs on teardown."
  }
  assert {
    condition     = google_container_node_pool.demo.upgrade_settings[0].max_surge == 0 && !google_container_node_pool.demo.node_config[0].spot
    error_message = "No surge capacity; Spot is opt-in."
  }
}

run "pause" {
  command = plan
  variables { paused = true }
  assert {
    condition     = google_container_node_pool.demo.node_count == 0
    error_message = "Pause scales only worker count to zero."
  }
}

run "spot" {
  command = plan
  variables { spot = true }
  assert {
    condition     = google_container_node_pool.demo.node_config[0].spot
    error_message = "Spot must be selectable."
  }
}

run "reject_open_admin" {
  command = plan
  variables { admin_cidr = "0.0.0.0/0" }
  expect_failures = [var.admin_cidr]
}
