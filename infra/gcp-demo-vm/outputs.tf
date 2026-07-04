output "instance_name" {
  value = google_compute_instance.demo.name
}

output "zone" {
  value = google_compute_instance.demo.zone
}

output "region" {
  value = var.region
}

output "external_ip" {
  value = google_compute_instance.demo.network_interface[0].access_config[0].nat_ip
}

output "demo_url" {
  value = "http://${google_compute_instance.demo.network_interface[0].access_config[0].nat_ip}:${var.demo_port}"
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.demo.name} --zone ${var.zone} --project ${var.project_id}"
}

output "labels" {
  value = google_compute_instance.demo.labels
}
