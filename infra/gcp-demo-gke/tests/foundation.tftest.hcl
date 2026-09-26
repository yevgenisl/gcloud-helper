mock_provider "google" {}

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
