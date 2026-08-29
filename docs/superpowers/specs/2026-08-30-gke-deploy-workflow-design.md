# Design: Minimal GitHub Actions CI/CD to GKE

**Date:** 2026-08-30
**Status:** Approved (pending doc review)

## Context

This repo (`Urable-org/microservices-demo`, a fork of Google's Online Boutique demo)
has a GKE Autopilot cluster (`online-boutique`, GCP project
`hl2-gcpp-ccoe-ge-h-itrace-1647`, region `us-central1`) provisioned by
`terraform/`, with a dedicated VPC/subnet/NAT (`terraform/network.tf`). The app
was deployed to it once, manually, via a `local-exec` provisioner running
`kubectl apply -k kustomize/` during `terraform apply`.

The repo's existing `.github/workflows/*` (ci-pr, ci-main, deploy-pr, cleanup,
make-release, etc.) all authenticate against **Google's own** upstream CI
infrastructure (project `online-boutique-ci`, cluster `prs-gke-cluster`, a
Workload Identity Federation provider under project number `816257685787`).
None of them can reach or are meant to reach this fork's cluster. There is
currently no workflow that deploys to this fork's own cluster.

## Goal

A new, minimal GitHub Actions workflow that, on every push to `main` touching
service source or manifests, builds the changed microservices' container
images, pushes them to this project's own Artifact Registry, and deploys them
to the `online-boutique` GKE cluster — without depending on or modifying any
of Google's upstream CI workflows.

## Non-goals

- Multi-arch (arm64) builds — the Autopilot cluster runs amd64 nodes only.
- PR preview environments, smoke tests, or IP-comment-on-PR — that's what
  `deploy-pr.yaml` already does against the *upstream* cluster; out of scope
  for this fork's own deploy path.
- Changing any of the 9 existing workflow files.
- Cloud Build — build happens in GitHub Actions, not offloaded to GCP.

## Architecture

```
push to main (src/**, kustomize/**)
        |
        v
+-------------------+        +--------------------+
|  build (matrix)    |  -->   |  deploy             |
|  11 services        |        |  kustomize edit set |
|  docker build+push  |        |  image ... x11      |
|  -> Artifact        |        |  kubectl apply -k   |
|     Registry        |        |  kubectl wait        |
+-------------------+        +--------------------+
        |                              |
        v                              v
   Workload Identity Federation (keyless GCP auth, both jobs)
```

## 1. Terraform changes

### New file: `terraform/wif.tf`

Provisions everything the workflow needs to authenticate and push images,
scoped tightly to this one GitHub repo:

- `google_artifact_registry_repository.microservices_demo` — Docker format,
  `location = var.region`, `repository_id = "microservices-demo"`. Images
  live at `us-central1-docker.pkg.dev/hl2-gcpp-ccoe-ge-h-itrace-1647/microservices-demo/<service>`.
- `google_service_account.github_action_runner` — id `github-action-runner`,
  the identity GitHub Actions impersonates. Mirrors the naming convention
  Google's own upstream workflows use for their equivalent SA.
- `google_iam_workload_identity_pool.github_actions_pool` (id
  `github-actions-pool`) + `google_iam_workload_identity_pool_provider.github_provider`
  (id `github-provider`) — OIDC trust with `https://token.actions.githubusercontent.com`.
  **Attribute condition restricts the trust to
  `assertion.repository == "Urable-org/microservices-demo"`** — no other
  GitHub repo, fork, or org can mint a token that impersonates this SA.
- `google_service_account_iam_member` — grants the pool's principal set
  `roles/iam.workloadIdentityUser` on `github_action_runner`.
- `google_project_iam_member` x2 — grants `github_action_runner`
  `roles/artifactregistry.writer` (push images) and `roles/container.developer`
  (deploy workloads to the GKE cluster) on the project.

### Append to `terraform/output.tf`

```hcl
output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github_provider.name
}

output "deploy_service_account_email" {
  value = google_service_account.github_action_runner.email
}
```

After `terraform apply`, these two values get copied verbatim into the new
workflow file's `auth` step (hardcoded, not a GitHub secret — consistent with
how the existing workflows already embed their WIF provider path and SA email
directly in YAML, since neither value is sensitive on its own).

### Remove from `terraform/main.tf`

`null_resource.get_credentials`, `null_resource.apply_deployment`,
`null_resource.wait_conditions`, and their `provisioner` blocks. Terraform
becomes infra-only (network, cluster, IAM, registry); the new GitHub Actions
workflow becomes the single owner of app deployment. This also removes the
drift risk where a future `terraform apply` (e.g. a network tweak) would
silently reset the cluster back to stock upstream images.

### Remove from `terraform/variables.tf`

`variable "namespace"` and `variable "filepath_manifest"` — both become
unused once the null_resources above are removed (confirmed: grep shows no
other reference to either variable anywhere in `terraform/`).

## 2. New workflow: `.github/workflows/deploy-gke.yaml`

### Trigger

```yaml
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
```

`cancel-in-progress: false` because a deploy that's already mid-`kubectl
apply` shouldn't be killed by a fast-following push — the next run just
queues behind it.

### Job `build` (matrix, `fail-fast: false`)

One matrix entry per service that's actually part of `kustomize/base`:
adservice, cartservice (context `src/cartservice/src`), checkoutservice,
currencyservice, emailservice, frontend, loadgenerator, paymentservice,
productcatalogservice, recommendationservice, shippingservice — 11 total.
`shoppingassistantservice` is skipped (optional kustomize component, not
deployed by default); `redis-cart` is never rebuilt (stock public image).

Steps per matrix entry:
1. `actions/checkout@v7`
2. `google-github-actions/auth@v3` — WIF, `workload_identity_provider` and
   `service_account` from the Terraform outputs above
3. `google-github-actions/setup-gcloud@v2`
4. `gcloud auth configure-docker us-central1-docker.pkg.dev --quiet`
5. `docker/setup-buildx-action@v4`
6. `docker/build-push-action@v6` — context `src/<service>` (or
   `src/cartservice/src`), tag
   `us-central1-docker.pkg.dev/hl2-gcpp-ccoe-ge-h-itrace-1647/microservices-demo/<service>:${{ github.sha }}`,
   `cache-from`/`cache-to: type=gha` for layer caching across runs

### Job `deploy` (`needs: build`)

1. `actions/checkout@v7`
2. WIF auth (same as build)
3. `setup-gcloud` with `install_components: gke-gcloud-auth-plugin` — avoids
   the exact `gke-gcloud-auth-plugin.exe not found` error hit during the
   manual `terraform apply`
4. `gcloud container clusters get-credentials online-boutique --region us-central1 --project hl2-gcpp-ccoe-ge-h-itrace-1647`
5. Install the `kustomize` CLI binary (needed for `kustomize edit`, which
   `kubectl`'s built-in kustomize renderer doesn't expose)
6. In `kustomize/`, for each of the 11 services:
   `kustomize edit set image <upstream-image>=<our-AR-repo>/<service>:${{ github.sha }}`
   — rewrites the `images:` list in `kustomize/kustomization.yaml` for this
   checkout only; never committed back to the repo.
7. `kubectl apply -k kustomize/`
8. `kubectl wait --for=condition=available --timeout=300s deployment/<name>`
   for all 12 deployments (11 rebuilt services + `redis-cart`), mirroring the
   wait step already used in `ci-main.yaml`.

No smoke test, no external-IP PR comment — that's PR-preview-specific
plumbing that already exists in `deploy-pr.yaml` for the upstream cluster;
out of scope here.

## One-time manual setup (after this change is merged)

1. `cd terraform && terraform apply` — creates the AR repo, WIF pool/provider,
   and service account; removes the old app-deploy null_resources.
2. `terraform output workload_identity_provider` and
   `terraform output deploy_service_account_email` — paste both values into
   the `auth` step of `.github/workflows/deploy-gke.yaml` (two placeholders
   marked `# TODO: fill in after terraform apply`).
3. Push to `main` (or run the workflow via `workflow_dispatch`) to trigger the
   first build+deploy.

## Testing plan

- `terraform validate` (already covered by `terraform-validate-ci.yaml`) after
  the `wif.tf` addition and `main.tf`/`variables.tf` removals.
- `kubectl kustomize kustomize/` locally (or `kustomize-build-ci.yaml`) still
  renders cleanly after the workflow's `kustomize edit set image` step is
  reverted (it's not — verify with a local dry run: `kustomize edit set
  image` + `kubectl apply --dry-run=client -k kustomize/`).
- After merge: watch the first `workflow_dispatch` run end-to-end, confirm all
  12 deployments report `Available`, and confirm the images actually pulled
  are tagged with the triggering commit's SHA (`kubectl get deploy -o
  jsonpath='{.items[*].spec.template.spec.containers[*].image}'`).
