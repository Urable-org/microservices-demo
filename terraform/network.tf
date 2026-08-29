# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Dedicated VPC for the GKE cluster (this project has no default network)
resource "google_compute_network" "vpc" {
  name                    = var.network
  project                 = var.gcp_project_id
  auto_create_subnetworks = false

  depends_on = [
    module.enable_google_apis
  ]
}

resource "google_compute_subnetwork" "subnet" {
  name                     = var.subnetwork
  project                  = var.gcp_project_id
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.60.0.0/20"
  private_ip_google_access = true

  # Org policy constraints/compute.requireVpcFlowLogs mandates flow logs on all subnets.
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.61.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.62.0.0/20"
  }
}

# Allow all internal traffic within the cluster's network/subnet ranges
# (node-to-node, pod-to-pod, pod-to-service). New VPCs have no implicit
# allow rule for this, unlike GCP's legacy "default" auto-mode network.
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.network}-allow-internal"
  project = var.gcp_project_id
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.60.0.0/14"]
}

# Cloud NAT so the Autopilot cluster's private nodes can reach the
# internet/Google APIs (Autopilot nodes have no external IPs by default).
resource "google_compute_router" "router" {
  name    = "${var.network}-router"
  project = var.gcp_project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.network}-nat"
  project                            = var.gcp_project_id
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
