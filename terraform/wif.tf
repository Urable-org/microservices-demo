# Copyright 2026 Google LLC
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

# Docker repo that .github/workflows/deploy-gke.yaml pushes built
# microservice images to.
resource "google_artifact_registry_repository" "microservices_demo" {
  project       = var.gcp_project_id
  location      = var.region
  repository_id = "microservices-demo"
  format        = "DOCKER"

  depends_on = [
    module.enable_google_apis
  ]
}

# Identity GitHub Actions impersonates via Workload Identity Federation to
# push images and deploy to the GKE cluster. Never has a downloadable key.
resource "google_service_account" "github_action_runner" {
  project      = var.gcp_project_id
  account_id   = "github-action-runner"
  display_name = "GitHub Actions deploy runner"

  depends_on = [
    module.enable_google_apis
  ]
}

resource "google_project_iam_member" "github_action_runner_artifact_writer" {
  project = var.gcp_project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_action_runner.email}"
}

resource "google_project_iam_member" "github_action_runner_container_developer" {
  project = var.gcp_project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.github_action_runner.email}"
}

# WIF pool + OIDC provider trusting GitHub Actions' token issuer, scoped to
# this one repo so no other fork/org can impersonate the deploy identity.
resource "google_iam_workload_identity_pool" "github_actions_pool" {
  project                   = var.gcp_project_id
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions"

  depends_on = [
    module.enable_google_apis
  ]
}

resource "google_iam_workload_identity_pool_provider" "github_provider" {
  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_actions_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "assertion.repository == \"Urable-org/microservices-demo\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Only this repo's GitHub Actions tokens may impersonate the deploy SA.
resource "google_service_account_iam_member" "github_action_runner_workload_identity_user" {
  service_account_id = google_service_account.github_action_runner.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions_pool.name}/attribute.repository/Urable-org/microservices-demo"
}
