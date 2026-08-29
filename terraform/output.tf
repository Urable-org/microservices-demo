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

output "cluster_location" {
  description = "Location of the cluster"
  value       = resource.google_container_cluster.my_cluster.location
}

output "cluster_name" {
  description = "Name of the cluster"
  value       = resource.google_container_cluster.my_cluster.name
}

output "workload_identity_provider" {
  description = "Full resource name of the WIF provider; paste into the GitHub Actions workflow's auth step"
  value       = google_iam_workload_identity_pool_provider.github_provider.name
}

output "deploy_service_account_email" {
  description = "Service account GitHub Actions impersonates to deploy; paste into the workflow's auth step"
  value       = google_service_account.github_action_runner.email
}
