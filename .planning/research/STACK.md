# Stack Research

**Domain:** AWS EKS lab hardening — S3/DynamoDB Terraform backend + RDS Postgres pilot + ArgoCD GitOps + Dynatrace Operator observability
**Researched:** 2026-04-20
**Confidence:** HIGH for versions (live registry/docs verified); MEDIUM for a few Dynatrace token nuances noted inline

---

## Constraint Baseline (Do Not Re-Research)

The locked providers in `.terraform.lock.hcl` are immovable for this milestone:

| Provider | Constraint | Locked | Impact |
|---|---|---|---|
| `hashicorp/aws` | `~> 5.0` | `5.100.0` | All new resources must stay within AWS provider v5 API surface |
| `hashicorp/kubernetes` | `~> 2.0` | `2.38.0` | Any new k8s resources use this provider |
| `hashicorp/helm` | `~> 2.0` | `2.17.0` | All Helm releases (`argo-cd`, `dynatrace-operator`) go through this provider |
| `hashicorp/random` | transitive | `3.8.1` | Already present; safe to reference for `random_password` |

**Critical incompatibility to avoid:** `terraform-aws-modules/rds/aws` v7.x requires AWS provider `>= 6.27` and Terraform `>= 1.11`. This project locks `aws ~> 5.0`. Use **v6.x** of the RDS module only.

---

## Recommended Stack

### 1. Terraform S3 Backend + State Locking

| Technology | Version / Value | Purpose | Why |
|---|---|---|---|
| `terraform { backend "s3" }` | Terraform built-in | Remote state storage | Eliminates OneDrive sync corruption and token exposure risk |
| S3 bucket | AWS-managed, SSE-S3 (`encrypt = true`) | Encrypted state storage | AWS-managed SSE is zero-cost and zero-operational overhead; a CMK adds KMS cost and a second resource to bootstrap with no security benefit for a lab |
| `use_lockfile = true` | Terraform 1.10+ (stable in 1.11+) | S3-native state locking | Replaces DynamoDB locking; `dynamodb_table` is deprecated as of Terraform 1.11; S3 conditional writes are the forward-looking primitive |
| S3 versioning | `aws_s3_bucket_versioning` resource | State rollback | Required to recover from a corrupt state write |
| S3 bucket policy | `aws_s3_bucket_policy` resource | Deny non-SSL + restrict access | Defense-in-depth; prevents state being fetched over unencrypted HTTP |

**Bootstrap Pattern — Avoid the Chicken-and-Egg Problem**

The S3 bucket and associated resources must exist _before_ `backend "s3" {}` can be initialized. The cleanest pattern for a single-root module lab is:

1. Declare the backend S3 bucket as normal Terraform resources (`aws_s3_bucket`, `aws_s3_bucket_versioning`, `aws_s3_bucket_server_side_encryption_configuration`, `aws_s3_bucket_public_access_block`) in `main.tf` without a `backend {}` block. Apply with **local state** to create the bucket.
2. Add the `backend "s3" {}` block and run `terraform init` — Terraform will prompt to migrate local state into S3. Accept. Local `terraform.tfstate` becomes a stale artifact and can be deleted.
3. Commit the final `main.tf` (with backend block) and `.terraform.lock.hcl`.

Do **not** use `terraform apply -target` for this; it leaves partial dependency tracking. The two-phase init-migrate approach is idiomatic and well-tested.

**Backend block (final form):**

```hcl
terraform {
  required_version = ">= 1.10"
  backend "s3" {
    bucket       = "eks-trade-tfstate-<account_id>"
    key          = "easytrade-lab/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true        # SSE-S3; sufficient for a lab
    use_lockfile = true        # S3-native lock; no DynamoDB needed
  }
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.0" }
  }
}
```

**Why SSE-S3 over KMS CMK:**
- A CMK requires `aws_kms_key` + `aws_kms_alias` resources that must themselves exist before the backend is initialized — deepening the chicken-and-egg problem.
- For a lab with one operator, the security model of SSE-S3 is equivalent (encryption at rest, AWS-managed key rotation).
- KMS CMK is the right choice only when compliance mandates customer-managed key audit trails or cross-account access. Neither applies here.

**IAM permissions the principal running `terraform` must have on the bucket:**
`s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` (state file + `.tflock` file), `s3:ListBucket`, `s3:GetBucketVersioning`.

**Confidence:** HIGH — verified against [HashiCorp S3 backend docs](https://developer.hashicorp.com/terraform/language/backend/s3) and [Terraform 1.11 native locking announcement](https://medium.com/@mdotsalman/no-more-dynamodb-terraform-1-11-introduces-native-s3-lockfile-support-d668020bd88e).

---

### 2. RDS Postgres — Module and Engine

| Technology | Version | Purpose | Why |
|---|---|---|---|
| `terraform-aws-modules/rds/aws` | `~> 6.10` (latest 6.x; do NOT use 7.x) | RDS instance + subnet group + parameter group + option group | Community standard; wraps all the boilerplate resources; v6.x is the last series compatible with `aws ~> 5.0` |
| PostgreSQL engine | `17` (engine_version = `"17"`, let AWS resolve the minor patch) | AccountService DB | PostgreSQL 17 is GA on RDS as of 2025, well-supported, 5-year support window; PostgreSQL 16 is also safe but shorter runway |
| Instance class | `db.t4g.micro` | Lab cost | Graviton2, cheapest available Postgres instance; t4g.micro supports Postgres 12.7+ including 17 |
| Deployment | Single-AZ, `multi_az = false` | Lab cost | Explicit project constraint; no HA needed for a demo |

**Key module inputs for this project:**

```hcl
module "rds_accountservice" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.10"

  identifier        = "easytrade-accountservice"
  engine            = "postgres"
  engine_version    = "17"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
  storage_encrypted = true   # SSE with AWS-managed key; zero extra cost

  db_name  = "accountservice"
  username = "accountservice"

  # Password: use manage_master_user_password (Secrets Manager) — see below
  manage_master_user_password = true

  # Network
  create_db_subnet_group = true
  subnet_ids             = data.aws_subnets.private.ids
  vpc_security_group_ids = [aws_security_group.rds_accountservice.id]

  # No public access in a lab private subnet
  publicly_accessible = false
  multi_az            = false

  # Backup — minimal for lab, enable for any restore test
  backup_retention_period = 1
  skip_final_snapshot     = true

  # Parameter group — let the module create the default for postgres17
  family = "postgres17"
}
```

**Secrets Management — `manage_master_user_password = true`:**

This is the correct choice. It wires directly to AWS Secrets Manager without requiring a `random_password` resource. The generated secret ARN is exposed as `module.rds_accountservice.db_instance_master_user_secret_arn`. EasyTrade's AccountService deployment (managed by ArgoCD) can consume this via an External Secrets Operator sidecar or an init-container — the mechanism is deferred to the ArgoCD phase. The critical constraint is: **the password never appears in Terraform state or in Git**.

Do NOT use:
- `random_password` + `ignore_changes = [password]` — puts the plaintext password into Terraform state which lives in S3 (still an improvement over OneDrive, but avoidable).
- Hardcoded password in `terraform.tfvars` — would require gitignoring the file and is error-prone.

**Security group for RDS:**

Wire a dedicated SG: inbound port 5432 from the EKS node security group only (reference `module.eks.node_security_group_id`). This is a direct `aws_security_group` + `aws_vpc_security_group_ingress_rule` pair inline in `main.tf`.

**Confidence:** HIGH for module selection and version constraints — verified against [terraform-aws-rds GitHub releases](https://github.com/terraform-aws-modules/terraform-aws-rds/releases) (v7.0.0 changelog confirms `aws >= 6.27` requirement; v6.10.0 requires only `aws ~> 5.0`). MEDIUM for `engine_version = "17"` — PostgreSQL 17 is GA on RDS (verified against [AWS RDS PostgreSQL release notes](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-versions.html)) but confirm with `aws rds describe-db-engine-versions --engine postgres --engine-version 17 --region us-east-1` before apply to ensure the minor version selected by AWS is available in the chosen AZ.

---

### 3. ArgoCD on EKS

| Technology | Version | Purpose | Why |
|---|---|---|---|
| `argo/argo-cd` Helm chart | `9.5.2` (appVersion: ArgoCD v3.3.7) | Install ArgoCD on EKS | Official chart from argoproj; 9.x is the current stable series as of April 2025 |
| `argo/argocd-apps` Helm chart | `2.0.4` | Deploy the bootstrap ApplicationSet | Decoupled companion chart for Application/ApplicationSet resources; avoids deprecated `server.additionalApplications` in ArgoCD chart v5+ |
| Terraform `helm_release` | existing `~> 2.0` locked at `2.17.0` | Deliver both charts | No new provider needed |

**Chart repository:** `https://argoproj.github.io/argo-helm`

**Kubernetes compatibility:** Chart 9.5.2 requires `>= 1.25.0-0`; the cluster runs 1.34 — compatible.

**Helm values for a lab (non-HA):**

```hcl
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "9.5.2"
  namespace        = "argocd"
  create_namespace = true
  wait             = true     # Must be true; argocd-apps helm_release must wait for CRDs

  values = [<<-YAML
    server:
      service:
        type: ClusterIP   # Do not expose ArgoCD UI via LoadBalancer; use kubectl port-forward for lab access
    configs:
      params:
        server.insecure: "true"  # TLS termination at ingress level; acceptable for a lab without cert-manager
    redis-ha:
      enabled: false    # HA requires 3 nodes; SPOT single-node lab cannot guarantee this
    controller:
      replicas: 1
    server:
      replicas: 1
    repoServer:
      replicas: 1
    applicationSet:
      replicas: 1
  YAML
  ]
}
```

**Bootstrap ApplicationSet (deployed via `argocd-apps` chart):**

Use an **ApplicationSet with a Git directory generator** — not App-of-Apps. Reasoning:
- App-of-Apps requires manually creating child Application CRs in Git; adding a new app = writing a new YAML file.
- ApplicationSet with a `git` directory generator auto-discovers subdirectories under `gitops/` and creates an `Application` for each. Adding the EasyTrade Helm release to ArgoCD = dropping a directory into `gitops/apps/easytrade/`.
- For this lab there is no multi-cluster templating need (App-of-Apps strength), making ApplicationSet the cleaner primitive.

```hcl
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.4"
  namespace  = "argocd"
  wait       = true

  depends_on = [helm_release.argocd]

  values = [<<-YAML
    applicationsets:
      - name: easytrade-lab
        namespace: argocd
        spec:
          generators:
            - git:
                repoURL: https://github.com/<org>/<repo>.git
                revision: HEAD
                directories:
                  - path: gitops/apps/*
          template:
            metadata:
              name: "{{path.basename}}"
            spec:
              project: default
              source:
                repoURL: https://github.com/<org>/<repo>.git
                targetRevision: HEAD
                path: "{{path}}"
              destination:
                server: https://kubernetes.default.svc
                namespace: "{{path.basename}}"
              syncPolicy:
                automated:
                  prune: true
                  selfHeal: true
                syncOptions:
                  - CreateNamespace=true
  YAML
  ]
}
```

**Monorepo layout this implies:**

```
gitops/
  apps/
    easytrade/
      Chart.yaml     # Helm chart with chart pinned
      values.yaml
    (future services here)
```

**IRSA for private Git repos:** Not needed. The monorepo is public GitHub (or at minimum the ArgoCD service account does not need IAM credentials for repo access). If the repo is private, configure an ArgoCD repository credential via a `kubernetes_secret` resource instead of IRSA — SSH key or GitHub token stored in a k8s secret in the `argocd` namespace.

**Sync waves and finalizers:** Defer to individual app manifests in `gitops/`. The Terraform phase only needs to stand up the ApplicationSet controller and the root ApplicationSet. EasyTrade's own sync wave order (e.g., ensure the `easytrade` namespace exists before services) is expressed in the app's own Helm chart or Kustomize patches.

**ArgoCD EKS endpoint access:** ArgoCD's in-cluster API server call uses `https://kubernetes.default.svc` — works without modification because ArgoCD runs inside the cluster. No special EKS endpoint CIDR rule is needed for ArgoCD's control loop.

**Confidence:** HIGH — chart version 9.5.2 verified against [argo-helm GitHub releases](https://github.com/argoproj/argo-helm/releases) and [Artifact Hub](https://artifacthub.io/packages/helm/argo/argo-cd). ApplicationSet recommendation verified against [ArgoCD official docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/) and current community practice.

---

### 4. Dynatrace Operator on EKS

| Technology | Version | Purpose | Why |
|---|---|---|---|
| `dynatrace-operator` OCI Helm chart | `1.9.0` | Install CRDs, operator deployment, webhook, CSI driver | Latest stable release (April 13, 2025); OCI registry is the current/non-deprecated delivery mechanism |
| OCI repository | `oci://public.ecr.aws/dynatrace/dynatrace-operator` | Helm source | The `dynatrace/helm-charts` traditional repo is deprecated; use OCI |
| DynaKube CR | `cloudNativeFullStack` mode | OneAgent injection + host monitoring | See mode rationale below |
| Terraform `helm_release` | existing `~> 2.0` locked at `2.17.0` | Deliver the operator chart | The Helm provider's OCI support is stable since helm 2.9.x; locked 2.17.0 is sufficient |

**OCI chart in `helm_release`:**

```hcl
resource "helm_release" "dynatrace_operator" {
  name             = "dynatrace-operator"
  repository       = "oci://public.ecr.aws/dynatrace"
  chart            = "dynatrace-operator"
  version          = "1.9.0"
  namespace        = "dynatrace"
  create_namespace = true
  wait             = true
  atomic           = true

  # The operator itself needs no Helm values beyond what the DynaKube CR provides.
  # All monitoring configuration is in the DynaKube custom resource (applied separately).
}
```

**DynaKube CR — `cloudNativeFullStack` mode (recommended for EasyTrade):**

`cloudNativeFullStack` is the correct mode because:
- EasyTrade runs ~12 microservices as k8s pods. `cloudNativeFullStack` injects OneAgent code modules via an init-container + CSI volume triggered by the Dynatrace webhook — no pod restart needed for new deployments after the operator is ready.
- `classicFullStack` requires OneAgent to be running on the node _before_ a pod starts; any pod scheduled before the DaemonSet is Ready on its node will not be instrumented without a restart. Given SPOT node replacement patterns, this is a recurring operational nuisance.
- `applicationMonitoring` (app-only, no host metrics) is appropriate when you need lightweight injection without host-level telemetry. For a lab demo showcasing full Dynatrace value, `cloudNativeFullStack` is the right choice.

**Required tokens (two, not three):**

As of Dynatrace Operator 1.x, only two tokens are needed:
- `apiToken` — Operator token; used for communication with the Dynatrace API (must have scopes: `writeConfig`, `readConfig`, `PaasIntegration`, `activeGateTokenManagement`, `entities.read`, `settings.write`, `settings.read`, `DataExport`).
- `dataIngestToken` — Data ingest token; used by OneAgent modules to ship metrics and traces to the cluster ActiveGate (must have scope: `metrics.ingest`).

`paasToken` is a **legacy token type from pre-operator Dynatrace deployments**. The operator-based flow does not require it. Do not reference it in the secret.

**Token provisioning flow (tokens do not yet exist):**

Because the tenant exists but tokens do not, the provisioning order is:
1. Operator install (helm_release) — this is infrastructure; goes in Terraform apply.
2. In the Dynatrace UI: Settings → Integration → Dynatrace API → generate `apiToken` and `dataIngestToken` with the required scopes. This is a manual step — it cannot be done in Terraform without a Dynatrace Terraform provider (which is out of scope for this milestone).
3. Store tokens as a Kubernetes secret named `dynakube` in the `dynatrace` namespace:
   ```hcl
   resource "kubernetes_secret" "dynakube_tokens" {
     metadata {
       name      = "dynakube"
       namespace = "dynatrace"
     }
     data = {
       apiToken       = var.dynatrace_api_token
       dataIngestToken = var.dynatrace_data_ingest_token
     }
     type = "Opaque"
   }
   ```
   The token values are passed via `TF_VAR_dynatrace_api_token` / `TF_VAR_dynatrace_data_ingest_token` environment variables — never in `.tfvars` files committed to Git.
4. Apply the DynaKube CR as a `kubernetes_manifest` resource pointing at the `dynakube` secret:
   ```hcl
   resource "kubernetes_manifest" "dynakube" {
     manifest = {
       apiVersion = "dynatrace.com/v1beta5"
       kind       = "DynaKube"
       metadata = {
         name      = "dynakube"
         namespace = "dynatrace"
         annotations = {
           "feature.dynatrace.com/k8s-app-enabled"          = "true"
           "feature.dynatrace.com/injection-readonly-volume" = "true"
         }
       }
       spec = {
         apiUrl = "https://<ENVIRONMENT_ID>.live.dynatrace.com/api"
         metadataEnrichment = { enabled = true }
         oneAgent = {
           cloudNativeFullStack = {
             tolerations = [{
               effect   = "NoSchedule"
               key      = "node-role.kubernetes.io/master"
               operator = "Exists"
             }]
           }
         }
         activeGate = {
           capabilities = ["routing", "kubernetes-monitoring"]
         }
       }
     }
     depends_on = [
       helm_release.dynatrace_operator,
       kubernetes_secret.dynakube_tokens,
     ]
   }
   ```

**`kubernetes_manifest` vs raw `kubectl_manifest`:** Use the built-in `kubernetes_manifest` resource (kubernetes provider 2.38.0 supports this without a separate kubectl provider). The operator installs CRDs during the helm_release apply; `depends_on = [helm_release.dynatrace_operator]` ensures the CRD exists before the manifest is created.

**Confidence:** HIGH for chart version and OCI registry URL — verified against [dynatrace-operator GitHub releases](https://github.com/Dynatrace/dynatrace-operator/releases) and [Artifact Hub](https://artifacthub.io/packages/helm/dynatrace/dynatrace-operator). MEDIUM for token scope list — verified against [EKS DTO deployment docs](https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/marketplaces/eks-dto) and community posts; confirm exact required scopes in your Dynatrace tenant before token creation as scope names can vary by SaaS vs Managed.

---

## Supporting Resources (New Direct Resources, No New Modules)

| Resource | Purpose | Notes |
|---|---|---|
| `aws_s3_bucket` | State backend storage | Name must be globally unique; include account ID in the name |
| `aws_s3_bucket_versioning` | State rollback | Required; `status = "Enabled"` |
| `aws_s3_bucket_server_side_encryption_configuration` | Encryption at rest | `sse_algorithm = "AES256"` (SSE-S3) |
| `aws_s3_bucket_public_access_block` | Prevent public access | All four `block_*` booleans = `true` |
| `aws_s3_bucket_policy` | Deny HTTP, restrict principal | `aws:SecureTransport = false` deny condition |
| `aws_security_group` | RDS ingress control | Inbound 5432 from EKS node SG only |
| `aws_vpc_security_group_ingress_rule` | RDS SG rule | Source = `module.eks.node_security_group_id` |
| `kubernetes_secret` | Dynatrace tokens | `dynakube` secret in `dynatrace` namespace |
| `kubernetes_manifest` | DynaKube CR | Depends on operator helm_release + tokens secret |

---

## Alternatives Considered

| Recommendation | Alternative | Why Not |
|---|---|---|
| S3 backend with `use_lockfile = true` | DynamoDB table for locking | DynamoDB locking is deprecated in Terraform 1.11; `use_lockfile` is the forward path; adding a DynamoDB table is extra cost and complexity |
| SSE-S3 for backend bucket | KMS CMK | CMK requires bootstrapping the key before the bucket before the backend; extra cost; unnecessary for a lab |
| `terraform-aws-modules/rds/aws` v6.x | v7.x | v7.0.0 requires `aws >= 6.27` and Terraform >= 1.11; incompatible with the locked `aws ~> 5.0` provider |
| `manage_master_user_password = true` | `random_password` + `ignore_changes` | `random_password` writes plaintext to state; Secrets Manager keeps it out of state entirely |
| `cloudNativeFullStack` DynaKube mode | `classicFullStack` | `classicFullStack` has pod-restart-before-instrumentation issue on SPOT nodes; `cloudNativeFullStack` is webhook-based and handles pod scheduling order gracefully |
| `cloudNativeFullStack` DynaKube mode | `applicationMonitoring` | `applicationMonitoring` skips host-level metrics; `cloudNativeFullStack` gives the full EasyTrade demo value |
| ApplicationSet with Git directory generator | App-of-Apps (manual Application CRs) | App-of-Apps requires writing a new Application CR in Git for every service; ApplicationSet auto-discovers directories and is the current recommended pattern for monorepos |
| OCI Helm chart for Dynatrace Operator | Traditional Helm repo | `dynatrace/helm-charts` traditional repo is deprecated by Dynatrace; OCI (`public.ecr.aws/dynatrace`) is the current delivery mechanism |
| `argocd-apps` companion chart for ApplicationSet | Inline in ArgoCD chart via `server.additionalApplications` | `server.additionalApplications` was deprecated in ArgoCD chart v5.0.0; `argocd-apps` is the correct decoupled approach |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|---|---|---|
| `terraform-aws-modules/rds/aws` `~> 7.0` | Requires `aws >= 6.27` and Terraform `>= 1.11`; breaking API changes (`password` removed in favor of write-only `password_wo`); incompatible with locked `aws ~> 5.0` | `~> 6.10` — last series on AWS provider v5 |
| `dynamodb_table` in S3 backend | Deprecated in Terraform 1.11; scheduled for removal in a future minor release | `use_lockfile = true` (S3-native locking) |
| `aws_kms_key` CMK for backend bucket | Adds a resource that must pre-exist the backend, deepening bootstrap complexity; costs ~$1/month/key for a lab; SSE-S3 provides equivalent encryption | `encrypt = true` with SSE-S3 |
| Dynatrace `paasToken` | Legacy token type not required by Dynatrace Operator 1.x; was used in pre-operator (OneAgent installed via curl script) deployments | `apiToken` + `dataIngestToken` only |
| `helm_release` with `wait = false` for ArgoCD | ArgoCD CRDs must be registered before `argocd-apps` can apply ApplicationSet resources; `wait = false` causes the companion chart to fail on first apply | `wait = true` on `helm_release.argocd` |
| ArgoCD `classicFullStack` with SPOT nodes | OneAgent DaemonSet race: if a SPOT node is replaced and a new pod starts before OneAgent is Ready on that node, the pod is not instrumented until restart | `cloudNativeFullStack` (webhook-based, ordering-safe) |
| Dynatrace Operator via `aws-ia/eks-blueprints-addons` | The blueprints-addons module has a sub-addon for Dynatrace (`dynatrace_operator` key) but it points at the deprecated Helm repo and is not guaranteed to track the latest OCI-based release | Direct `helm_release` with OCI source |
| `kube-prometheus-stack`, `external-dns`, `cert-manager` | All available as blueprints-addons but explicitly disabled and out of scope; observability goes through Dynatrace Operator, not Prometheus | Dynatrace Operator only |

---

## Version Compatibility Matrix

| Component | Version | Compatible With | Verified |
|---|---|---|---|
| Terraform | `>= 1.10` (for `use_lockfile`) | AWS provider `~> 5.0` | Yes |
| `hashicorp/aws` | `5.100.0` (locked) | terraform-aws-modules/rds `~> 6.x` | Yes |
| `hashicorp/helm` | `2.17.0` (locked) | OCI Helm charts (stable since 2.9) | Yes |
| `hashicorp/kubernetes` | `2.38.0` (locked) | `kubernetes_manifest` resource (stable since 2.x) | Yes |
| `terraform-aws-modules/rds/aws` | `~> 6.10` | `aws ~> 5.0`, Terraform `>= 1.0` | Yes |
| `argo/argo-cd` chart | `9.5.2` (appVersion ArgoCD v3.3.7) | Kubernetes `>= 1.25`; cluster is 1.34 | Yes |
| `argo/argocd-apps` chart | `2.0.4` | ArgoCD v3.x (must install ArgoCD first) | Yes |
| `dynatrace-operator` OCI chart | `1.9.0` | Kubernetes `>= 1.19`; cluster is 1.34 | Yes |
| PostgreSQL | `17` (RDS) | `db.t4g.micro` (T4g supports Postgres 12.7+) | Yes |

**Flag for plan-time confirmation:** EKS 1.34 is at the leading edge of the supported Kubernetes window. Confirm `aws rds describe-db-engine-versions --engine postgres --engine-version 17 --region us-east-1` returns the instance class `db.t4g.micro` as available. T4g.micro + Postgres 17 + us-east-1 is expected to be available based on AWS docs, but minor AZ-level capacity constraints are worth validating before the first apply.

---

## Sources

- [HashiCorp S3 Backend Docs (v1.14.x)](https://developer.hashicorp.com/terraform/language/backend/s3) — `use_lockfile` param, KMS config, IAM permissions; HIGH confidence
- [Terraform S3 Native Locking — No More DynamoDB](https://medium.com/@mdotsalman/no-more-dynamodb-terraform-1-11-introduces-native-s3-lockfile-support-d668020bd88e) — DynamoDB deprecation timeline; MEDIUM confidence (secondary source, consistent with official docs)
- [terraform-aws-rds GitHub Releases](https://github.com/terraform-aws-modules/terraform-aws-rds/releases) — v7.0.0 changelog confirming AWS provider v6.27 requirement; v6.10.0 as latest v6 series; HIGH confidence
- [AWS RDS PostgreSQL Release Notes](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-versions.html) — PostgreSQL 17 GA status; HIGH confidence
- [argo-helm GitHub Releases](https://github.com/argoproj/argo-helm/releases) — chart 9.5.2, appVersion ArgoCD v3.3.7; HIGH confidence
- [ArgoCD Helm Chart README (argoproj/argo-helm)](https://github.com/argoproj/argo-helm/blob/main/charts/argo-cd/README.md) — `server.additionalApplications` deprecation, HA configuration; HIGH confidence
- [ArgoCD ApplicationSet Official Docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/) — Git directory generator usage; HIGH confidence
- [Artifact Hub — argocd-apps chart](https://artifacthub.io/packages/helm/argo/argocd-apps) — version 2.0.4; HIGH confidence
- [Artifact Hub — dynatrace-operator](https://artifacthub.io/packages/helm/dynatrace/dynatrace-operator) — version 1.9.0; HIGH confidence
- [Dynatrace Operator GitHub Releases](https://github.com/Dynatrace/dynatrace-operator/releases) — v1.9.0 latest stable; HIGH confidence
- [Dynatrace Full-Stack Observability Docs](https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/full-stack-observability) — DynaKube CR schema, `cloudNativeFullStack` mode, two-token requirement; HIGH confidence
- [Dynatrace EKS DTO Deployment Docs](https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/marketplaces/eks-dto) — token creation workflow; MEDIUM confidence (some details required cross-referencing with community posts)

---

*Stack research for: AWS EKS lab hardening milestone (S3 backend + RDS + ArgoCD + Dynatrace Operator)*
*Researched: 2026-04-20*
