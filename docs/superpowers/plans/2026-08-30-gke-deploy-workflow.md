# Minimal GKE Deploy Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GitHub Actions workflow that builds the 11 core microservices' Docker images, pushes them to a new Artifact Registry repo, and deploys them to this fork's own `online-boutique` GKE cluster via Workload Identity Federation — and remove the Terraform `null_resource`s that would otherwise fight it for ownership of the cluster's deployed state.

**Architecture:** Terraform provisions auth/registry infra only (WIF pool+provider, deploy service account, Artifact Registry repo — no more `kubectl apply` from Terraform). A new `.github/workflows/deploy-gke.yaml` owns app deployment going forward: a `build` job matrix-builds and pushes 11 images tagged with the commit SHA, then a `deploy` job rewrites `kustomize/kustomization.yaml`'s image list via the `kustomize` CLI and applies it to the cluster.

**Tech Stack:** Terraform (`hashicorp/google` 7.44.0), GitHub Actions (`google-github-actions/auth@v3`, `setup-gcloud@v2`, `docker/build-push-action@v6`), Kustomize CLI, `kubectl`.

## Global Constraints

- GCP project: `hl2-gcpp-ccoe-ge-h-itrace-1647`. Region: `us-central1`. Cluster: `online-boutique` (GKE Autopilot).
- GitHub repo trust must be scoped to exactly `Urable-org/microservices-demo` in the WIF provider's `attribute_condition` — no broader trust.
- Do not modify any of the 9 existing workflow files (`ci-pr.yaml`, `ci-main.yaml`, `deploy-pr.yaml`, `cleanup.yaml`, `make-release.yaml`, `kustomize-build-ci.yaml`, `helm-chart-ci.yaml`, `kubevious-manifests-ci.yaml`, `terraform-validate-ci.yaml`).
- No multi-arch builds (amd64 only), no PR preview/smoke-test logic, no Cloud Build — see design doc non-goals.
- 11 services to build (matches `kustomize/base/*.yaml` + a Dockerfile in `src/`): `adservice`, `cartservice` (build context `src/cartservice/src`), `checkoutservice`, `currencyservice`, `emailservice`, `frontend`, `loadgenerator`, `paymentservice`, `productcatalogservice`, `recommendationservice`, `shippingservice`. Excluded: `shoppingassistantservice` (optional component, not deployed by default), `redis-cart` (stock public image, never rebuilt).
- 12 Kubernetes Deployments to wait on after apply: the 11 above + `redis-cart`.
- Source spec: `docs/superpowers/specs/2026-08-30-gke-deploy-workflow-design.md`.

**Note on "testing" for this plan:** this change is Terraform + GitHub Actions YAML, not application code — there's no pytest/go-test suite to drive. Each task's verification step substitutes the closest equivalent: `terraform validate` (and, where noted, `terraform plan`) for Terraform tasks, and a local YAML-parse + kustomize/kubectl dry-run for workflow-YAML tasks. Run every verification step and confirm the stated expected output before moving on.

---

### Task 1: Terraform — provision Workload Identity Federation + Artifact Registry

**Files:**
- Modify: `terraform/main.tf:16-25` (locals block — add two APIs to `base_apis`)
- Create: `terraform/wif.tf`
- Modify: `terraform/output.tf` (append two outputs)

**Interfaces:**
- Produces: Terraform resources `google_artifact_registry_repository.microservices_demo`, `google_service_account.github_action_runner`, `google_iam_workload_identity_pool.github_actions_pool`, `google_iam_workload_identity_pool_provider.github_provider`. Outputs `workload_identity_provider` and `deploy_service_account_email`, whose values Task 5 pastes into the workflow file created in Tasks 3–4.

- [ ] **Step 1: Add the two APIs `wif.tf`'s resources need to `main.tf`'s `base_apis` list**

In `terraform/main.tf`, change:

```hcl
  base_apis = [
    "container.googleapis.com",
    "monitoring.googleapis.com",
    "cloudtrace.googleapis.com",
    "cloudprofiler.googleapis.com"
  ]
```

to:

```hcl
  base_apis = [
    "container.googleapis.com",
    "monitoring.googleapis.com",
    "cloudtrace.googleapis.com",
    "cloudprofiler.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com"
  ]
```

(`artifactregistry.googleapis.com` isn't enabled by default on a fresh project; `iam.googleapis.com` backs the Workload Identity Pool resources below.)

- [ ] **Step 2: Create `terraform/wif.tf`**

```hcl
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
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
  }

  attribute_condition = "assertion.repository == \"Urable-org/microservices-demo\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Only this repo's GitHub Actions tokens may impersonate the deploy SA.
resource "google_service_account_iam_member" "github_action_runner_workload_identity_user" {
  service_account_id = google_service_account.github_action_runner.name
  role                = "roles/iam.workloadIdentityUser"
  member              = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_actions_pool.name}/attribute.repository/Urable-org/microservices-demo"
}
```

- [ ] **Step 3: Append outputs to `terraform/output.tf`**

Add after the existing `cluster_name` output block:

```hcl

output "workload_identity_provider" {
  description = "Full resource name of the WIF provider; paste into the GitHub Actions workflow's auth step"
  value       = google_iam_workload_identity_pool_provider.github_provider.name
}

output "deploy_service_account_email" {
  description = "Service account GitHub Actions impersonates to deploy; paste into the workflow's auth step"
  value       = google_service_account.github_action_runner.email
}
```

- [ ] **Step 4: Validate**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

Run: `cd terraform && terraform fmt -check -diff`
Expected: no output (already formatted). If it prints a diff, run `terraform fmt` and re-check.

- [ ] **Step 5: Commit**

```bash
git add terraform/main.tf terraform/wif.tf terraform/output.tf
git commit -m "Add Terraform WIF pool, deploy service account, and Artifact Registry repo"
```

---

### Task 2: Terraform — remove Terraform-driven `kubectl apply` and its now-unused variables

**Files:**
- Modify: `terraform/main.tf:16-25,68-105`
- Modify: `terraform/variables.tf:32-42`

**Interfaces:**
- Consumes: nothing new from Task 1.
- Produces: `terraform/main.tf` becomes infra-only (network, cluster, IAM, registry). No task after this depends on the removed variables or resources — confirmed by `grep -n "var\.\(namespace\|filepath_manifest\)"` returning matches only on the lines being deleted here.

- [ ] **Step 1: Remove the three app-deploying `null_resource`s from `terraform/main.tf`**

Delete these three blocks (lines 68–105 in the current file), including their leading comments:

```hcl
# Get credentials for cluster
resource "null_resource" "get_credentials" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = "gcloud container clusters get-credentials ${local.cluster_name} --zone=${var.region} --project=${var.gcp_project_id}"
  }

  depends_on = [
    google_container_cluster.my_cluster
  ]
}

# Apply YAML kubernetes-manifest configurations
resource "null_resource" "apply_deployment" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = "kubectl apply -k ${var.filepath_manifest} -n ${var.namespace}"
  }

  depends_on = [
    null_resource.get_credentials
  ]
}

# Wait condition for all Pods to be ready before finishing
resource "null_resource" "wait_conditions" {
  provisioner "local-exec" {
    interpreter = ["bash", "-exc"]
    command     = <<-EOT
    kubectl wait --for=condition=AVAILABLE apiservice/v1beta1.metrics.k8s.io --timeout=180s
    kubectl wait --for=condition=ready pods --all -n ${var.namespace} --timeout=280s
    EOT
  }

  depends_on = [
    resource.null_resource.apply_deployment
  ]
}
```

The file should end right after the `google_container_cluster.my_cluster` resource's closing `}`.

- [ ] **Step 2: Remove the now-unused `cluster_name` local**

In the same file's `locals` block, change:

```hcl
  memorystore_apis = ["redis.googleapis.com"]
  cluster_name     = google_container_cluster.my_cluster.name
}
```

to:

```hcl
  memorystore_apis = ["redis.googleapis.com"]
}
```

(`local.cluster_name` was only ever read inside `null_resource.get_credentials`, removed in Step 1.)

- [ ] **Step 3: Remove the two now-unused variables from `terraform/variables.tf`**

Delete:

```hcl
variable "namespace" {
  type        = string
  description = "Kubernetes Namespace in which the Online Boutique resources are to be deployed"
  default     = "default"
}

variable "filepath_manifest" {
  type        = string
  description = "Path to Online Boutique's Kubernetes resources, written using Kustomize"
  default     = "../kustomize/"
}
```

- [ ] **Step 4: Validate**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

Run: `cd terraform && terraform plan`
Expected: plan shows only destroys for `null_resource.get_credentials`, `null_resource.apply_deployment`, `null_resource.wait_conditions` (plus the Task 1 additions as creates) — no changes to `google_container_cluster.my_cluster` or networking resources. `terraform plan` is read-only against GCP state; it does not require applying.

- [ ] **Step 5: Commit**

```bash
git add terraform/main.tf terraform/variables.tf
git commit -m "Remove Terraform-driven kubectl apply now that deploy-gke.yaml owns app deployment"
```

---

### Task 3: GitHub Actions — create `deploy-gke.yaml` with trigger and build job

**Files:**
- Create: `.github/workflows/deploy-gke.yaml`

**Interfaces:**
- Produces: top-level `env` keys `PROJECT_ID`, `REGION`, `AR_REPO`, `WORKLOAD_IDENTITY_PROVIDER`, `DEPLOY_SERVICE_ACCOUNT` — Task 4's `deploy` job (added to this same file) reads all five. `WORKLOAD_IDENTITY_PROVIDER` and `DEPLOY_SERVICE_ACCOUNT` carry literal placeholder values filled in for real during Task 5's manual setup.

- [ ] **Step 1: Write the workflow's trigger, permissions, and `build` job**

```yaml
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

name: "Deploy to GKE"
on:
  push:
    branches: [main]
    paths:
      - 'src/**'
      - 'kustomize/**'
      - '.github/workflows/deploy-gke.yaml'
  workflow_dispatch: {}

concurrency:
  group: deploy-gke
  cancel-in-progress: false

permissions:
  contents: read
  id-token: write

env:
  PROJECT_ID: "hl2-gcpp-ccoe-ge-h-itrace-1647"
  REGION: "us-central1"
  AR_REPO: "us-central1-docker.pkg.dev/hl2-gcpp-ccoe-ge-h-itrace-1647/microservices-demo"
  WORKLOAD_IDENTITY_PROVIDER: "projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/github-actions-pool/providers/github-provider" # TODO: fill in after terraform apply
  DEPLOY_SERVICE_ACCOUNT: "github-action-runner@hl2-gcpp-ccoe-ge-h-itrace-1647.iam.gserviceaccount.com" # TODO: confirm after terraform apply

jobs:
  build:
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix:
        service:
          - name: adservice
            context: src/adservice
          - name: cartservice
            context: src/cartservice/src
          - name: checkoutservice
            context: src/checkoutservice
          - name: currencyservice
            context: src/currencyservice
          - name: emailservice
            context: src/emailservice
          - name: frontend
            context: src/frontend
          - name: loadgenerator
            context: src/loadgenerator
          - name: paymentservice
            context: src/paymentservice
          - name: productcatalogservice
            context: src/productcatalogservice
          - name: recommendationservice
            context: src/recommendationservice
          - name: shippingservice
            context: src/shippingservice
    steps:
      - uses: actions/checkout@v7
      - id: auth
        uses: google-github-actions/auth@v3
        with:
          workload_identity_provider: ${{ env.WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ env.DEPLOY_SERVICE_ACCOUNT }}
      - uses: google-github-actions/setup-gcloud@v2
      - run: gcloud auth configure-docker ${{ env.REGION }}-docker.pkg.dev --quiet
      - uses: docker/setup-buildx-action@v4
      - uses: docker/build-push-action@v6
        with:
          context: ${{ matrix.service.context }}
          push: true
          tags: ${{ env.AR_REPO }}/${{ matrix.service.name }}:${{ github.sha }}
          cache-from: type=gha,scope=${{ matrix.service.name }}
          cache-to: type=gha,mode=max,scope=${{ matrix.service.name }}
```

(`scope=${{ matrix.service.name }}` on the GHA cache keeps the 11 matrix entries' layer caches separate — without it they'd all write to the same cache key and thrash each other.)

- [ ] **Step 2: Validate YAML syntax**

Run: `python -c "import yaml; d=yaml.safe_load(open('.github/workflows/deploy-gke.yaml')); print(len(d['jobs']['build']['strategy']['matrix']['service']))"`
Expected: `11`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy-gke.yaml
git commit -m "Add deploy-gke.yaml build job: matrix build+push of 11 service images"
```

---

### Task 4: GitHub Actions — add the `deploy` job

**Files:**
- Modify: `.github/workflows/deploy-gke.yaml` (append `deploy` job under `jobs:`)

**Interfaces:**
- Consumes: `env.PROJECT_ID`, `env.REGION`, `env.AR_REPO`, `env.WORKLOAD_IDENTITY_PROVIDER`, `env.DEPLOY_SERVICE_ACCOUNT` from Task 3. Runs after `build` via `needs: build`.

- [ ] **Step 1: Append the `deploy` job**

Add this job under the existing `jobs:` key, as a sibling of `build` (same indentation level):

```yaml
  deploy:
    runs-on: ubuntu-24.04
    needs: build
    steps:
      - uses: actions/checkout@v7
      - id: auth
        uses: google-github-actions/auth@v3
        with:
          workload_identity_provider: ${{ env.WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ env.DEPLOY_SERVICE_ACCOUNT }}
      - uses: google-github-actions/setup-gcloud@v2
        with:
          install_components: 'gke-gcloud-auth-plugin'
      - run: gcloud container clusters get-credentials online-boutique --region ${{ env.REGION }} --project ${{ env.PROJECT_ID }}
      - name: Install kustomize
        run: |
          curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
          sudo mv kustomize /usr/local/bin/kustomize
      - name: Set image tags
        working-directory: kustomize
        run: |
          kustomize edit set image \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/adservice=${{ env.AR_REPO }}/adservice:${{ github.sha }} \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/cartservice=${{ env.AR_REPO }}/cartservice:${{ github.sha }} \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/checkoutservice=${{ env.AR_REPO }}/checkoutservice:${{ github.sha }} \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/currencyservice=${{ env.AR_REPO }}/currencyservice:${{ github.sha }} \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/emailservice=${{ env.AR_REPO }}/emailservice:${{ github.sha }} \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/frontend=${{ env.AR_REPO }}/frontend:${{ github.sha }} \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/loadgenerator=${{ env.AR_REPO }}/loadgenerator:${{ github.sha }} \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/paymentservice=${{ env.AR_REPO }}/paymentservice:${{ github.sha }} \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/productcatalogservice=${{ env.AR_REPO }}/productcatalogservice:${{ github.sha }} \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/recommendationservice=${{ env.AR_REPO }}/recommendationservice:${{ github.sha }} \
            us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/shippingservice=${{ env.AR_REPO }}/shippingservice:${{ github.sha }}
      - name: Apply manifests
        run: kubectl apply -k kustomize/
      - name: Wait for rollout
        run: |
          set -x
          kubectl wait --for=condition=available --timeout=300s deployment/redis-cart
          kubectl wait --for=condition=available --timeout=300s deployment/adservice
          kubectl wait --for=condition=available --timeout=300s deployment/cartservice
          kubectl wait --for=condition=available --timeout=300s deployment/checkoutservice
          kubectl wait --for=condition=available --timeout=300s deployment/currencyservice
          kubectl wait --for=condition=available --timeout=300s deployment/emailservice
          kubectl wait --for=condition=available --timeout=300s deployment/frontend
          kubectl wait --for=condition=available --timeout=300s deployment/loadgenerator
          kubectl wait --for=condition=available --timeout=300s deployment/paymentservice
          kubectl wait --for=condition=available --timeout=300s deployment/productcatalogservice
          kubectl wait --for=condition=available --timeout=300s deployment/recommendationservice
          kubectl wait --for=condition=available --timeout=300s deployment/shippingservice
```

- [ ] **Step 2: Validate YAML syntax**

Run: `python -c "import yaml; d=yaml.safe_load(open('.github/workflows/deploy-gke.yaml')); print(list(d['jobs'].keys())); print(d['jobs']['deploy']['needs'])"`
Expected: `['build', 'deploy']` then `build`

- [ ] **Step 3: Dry-run the `kustomize edit set image` + apply logic locally**

This exercises the exact substitution the `deploy` job performs, without needing a live cluster or the WIF credentials that don't exist yet.

```bash
cd kustomize
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
./kustomize edit set image \
  us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/adservice=us-central1-docker.pkg.dev/hl2-gcpp-ccoe-ge-h-itrace-1647/microservices-demo/adservice:test-sha \
  us-central1-docker.pkg.dev/online-boutique-ci/microservices-demo/cartservice=us-central1-docker.pkg.dev/hl2-gcpp-ccoe-ge-h-itrace-1647/microservices-demo/cartservice:test-sha
kubectl kustomize . | grep "image:"
```

Expected: the `grep` output shows `adservice` and `cartservice` now pointing at `us-central1-docker.pkg.dev/hl2-gcpp-ccoe-ge-h-itrace-1647/microservices-demo/...:test-sha`, while every other service's `image:` line is untouched (still `us-central1-docker.pkg.dev/online-boutique-ci/...`).

Then revert the scratch edit and remove the downloaded binary — this must not be committed:

```bash
git checkout -- kustomization.yaml
rm -f kustomize
cd ..
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy-gke.yaml
git commit -m "Add deploy-gke.yaml deploy job: kustomize image rewrite + apply + wait"
```

---

### Task 5: One-time manual GCP setup (human-run, after this PR merges — NOT part of implementing this plan)

This task is not code. It is real, billable, live-infrastructure-mutating GCP work, so per the git/infra safety rules it must be run by the user explicitly, not by whichever agent implements Tasks 1–4. Record it here so nothing gets lost, but do not execute Steps 1–2 automatically.

- [ ] **Step 1 (manual): Apply the Terraform changes**

```bash
cd terraform
terraform apply
```

Review the plan output before typing `yes` — expect creates for the Task 1 resources and destroys for the three `null_resource`s removed in Task 2, nothing else.

- [ ] **Step 2 (manual): Fill in the two TODOs in `deploy-gke.yaml`**

```bash
cd terraform
terraform output -raw workload_identity_provider
terraform output -raw deploy_service_account_email
```

Paste the first value into `WORKLOAD_IDENTITY_PROVIDER` and the second into `DEPLOY_SERVICE_ACCOUNT` in `.github/workflows/deploy-gke.yaml`'s `env:` block (replacing the two `# TODO` lines), then:

```bash
git add .github/workflows/deploy-gke.yaml
git commit -m "Fill in WIF provider and deploy service account from terraform output"
git push
```

- [ ] **Step 3 (manual): Trigger the first run**

Either push to `main`, or run it directly: `gh workflow run deploy-gke.yaml`. Watch it in the Actions tab; confirm all 11 build matrix entries succeed and the `deploy` job's final `kubectl wait` step reports all 12 deployments `Available`.

Verify the deployed images actually carry the triggering commit's SHA:

```bash
kubectl get deploy -o jsonpath='{.items[*].spec.template.spec.containers[*].image}'
```

---

## Self-Review

**Spec coverage:**
- Terraform: AR repo, SA, WIF pool/provider with repo-scoped attribute condition, IAM bindings, two outputs → Task 1. ✓
- Terraform removals (3 null_resources, 2 variables) → Task 2. ✓
- Workflow trigger/permissions/concurrency, build job matrix (11 services incl. cartservice's nested context), GHA caching → Task 3. ✓
- Deploy job (WIF auth, gke-gcloud-auth-plugin, get-credentials, kustomize edit set image x11, apply, wait on 12 deployments) → Task 4. ✓
- One-time manual setup (terraform apply, paste outputs, trigger first run) → Task 5, explicitly marked manual. ✓
- Testing plan (terraform validate, kustomize/kubectl dry run, post-merge image-tag check) → folded into Tasks 1, 2, 4's verification steps and Task 5 Step 3. ✓

**Placeholder scan:** The two `# TODO: fill in after terraform apply` comments in Task 3's YAML are not plan placeholders — they're the literal text the design doc specifies shipping in the file, because the real values don't exist until Task 5's live `terraform apply` runs. Task 5 spells out the exact commands that replace them. No other TODOs, TBDs, or "handle this later" language appears in Tasks 1–4.

**Type/name consistency:** Service names and build contexts in Task 3's matrix match the `image:` names used in Task 4's `kustomize edit set image` calls and the `kubectl wait` deployment names, cross-checked against `kustomize/base/*.yaml` and `src/*/Dockerfile`. `env.AR_REPO`, `env.REGION`, `env.PROJECT_ID`, `env.WORKLOAD_IDENTITY_PROVIDER`, `env.DEPLOY_SERVICE_ACCOUNT` are defined once in Task 3 and only ever read (never redefined) in Task 4. Terraform output names (`workload_identity_provider`, `deploy_service_account_email`) match exactly between Task 1's `output.tf` and Task 5's `terraform output` commands.
