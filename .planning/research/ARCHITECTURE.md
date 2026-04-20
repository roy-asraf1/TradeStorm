# Architecture Research

**Domain:** AWS EKS lab hardening — Terraform backend + RDS + ArgoCD GitOps + Dynatrace Operator
**Researched:** 2026-04-20
**Confidence:** HIGH (architecture patterns well-established; cutover mechanics verified against ArgoCD docs)

---

## Overview: What Changes in This Milestone

The existing stack is a flat single-root Terraform module where Terraform owns everything end-to-end: cluster creation, addon installation, app deployment via `helm_release.easytrade`, and ingress. After this milestone, the ownership boundary shifts:

- **Terraform owns:** infra (cluster, networking lookups, RDS, ArgoCD as a cluster addon, Dynatrace Operator as a cluster addon, ingress resource)
- **ArgoCD owns:** application lifecycle (EasyTrade Helm release, future app changes)
- **Git owns:** the desired application state (values, chart version pinned in `gitops/`)

The flat `main.tf` grows two new Terraform-managed sections (RDS around section 3.5, ArgoCD at section 4.5, Dynatrace Operator at section 4.6) and **loses** section 5 (`helm_release.easytrade`). A new top-level `gitops/` folder appears in the repo.

---

## System Overview (Post-Milestone)

```
┌──────────────────────────────────────────────────────────────────────┐
│  CONTROL PLANE (Terraform-owned)                                     │
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌────────────────┐               │
│  │  S3 bucket  │  │  DynamoDB   │  │  Terraform      │               │
│  │  (tfstate)  │  │  (locks)    │  │  state (remote) │               │
│  └─────────────┘  └─────────────┘  └────────────────┘               │
│                                                                      │
│  AWS Account  ──────────────────────────────────────────────────     │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │  np-lab VPC (existing, adopted via data sources)             │    │
│  │  ┌────────────────────────────────────────────────────────┐  │    │
│  │  │  Private Subnets                                       │  │    │
│  │  │  ┌─────────────┐  ┌──────────────────────────────┐    │  │    │
│  │  │  │  RDS (PG)   │  │  EKS Cluster (easytrade-lab) │    │  │    │
│  │  │  │  db.t4g.micro│  │  ┌────────┐  ┌───────────┐  │    │  │    │
│  │  │  │  Single-AZ  │  │  │  ALB   │  │  ArgoCD   │  │    │  │    │
│  │  │  │  SG: 5432   │  │  │  Ctrl  │  │  (addon)  │  │    │  │    │
│  │  │  └─────────────┘  │  └────────┘  └───────────┘  │    │  │    │
│  │  │                   │  ┌──────────────────────────┐│    │  │    │
│  │  │                   │  │  dynatrace namespace      ││    │  │    │
│  │  │                   │  │  DT Operator + DynaKube   ││    │  │    │
│  │  │                   │  └──────────────────────────┘│    │  │    │
│  │  │                   │  ┌──────────────────────────┐│    │  │    │
│  │  │                   │  │  easytrade namespace       ││    │  │    │
│  │  │                   │  │  EasyTrade (ArgoCD-owned) ││    │  │    │
│  │  │                   │  │  AccountService → RDS SG  ││    │  │    │
│  │  │                   │  └──────────────────────────┘│    │  │    │
│  │  │                   └──────────────────────────────┘    │  │    │
│  │  └────────────────────────────────────────────────────────┘  │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  AWS Secrets Manager                                                  │
│  ┌──────────────────────────────────────┐                            │
│  │  rds/accountservice/credentials      │                            │
│  │  dynatrace/operator-tokens           │                            │
│  └──────────────────────────────────────┘                            │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  APP PLANE (ArgoCD-owned, Git-sourced)                               │
│                                                                      │
│  GitHub / this repo                                                  │
│  gitops/                                                             │
│    apps/easytrade/Application.yaml   ──────────────────────────────► │
│    apps/easytrade/values.yaml                  ArgoCD watches        │
│    (optional) apps/root/Application.yaml       gitops/ path,         │
│                                                reconciles to cluster │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow Diagrams

### Apply-Time Data Flow (Terraform)

```
terraform apply
      │
      ├─ 1. backend "s3" ──► reads/writes state from S3; locks via DynamoDB
      │
      ├─ 2. data.aws_vpc / data.aws_subnets (unchanged)
      │
      ├─ 3. module.eks (unchanged)
      │           │
      │           ├─ produces: cluster_name, cluster_endpoint, oidc_provider_arn
      │           └─ produces: node_group SG id (used by RDS SG rule)
      │
      ├─ 3.5 RDS section (NEW)
      │   ├─ aws_db_subnet_group  ─────── consumes: data.aws_subnets.private.ids
      │   ├─ aws_security_group.rds_sg ── allows 5432 from module.eks node SG
      │   ├─ aws_db_instance.accountservice
      │   │       consumes: subnet_group, rds_sg, credentials via random_password
      │   └─ aws_secretsmanager_secret  ── stores {host, port, user, pass}
      │
      ├─ 4. module.eks_blueprints_addons (ALB Controller — unchanged)
      │
      ├─ 4.5 ArgoCD (NEW)
      │   └─ helm_release.argocd
      │           consumes: data.aws_eks_cluster* (provider auth)
      │           depends_on: module.eks_blueprints_addons
      │           produces: argocd namespace + ArgoCD server running
      │
      ├─ 4.6 Dynatrace Operator (NEW)
      │   ├─ helm_release.dynatrace_operator
      │   │       consumes: provider auth (same as argocd)
      │   │       depends_on: helm_release.argocd (optional; prevents race on CRDs)
      │   ├─ kubernetes_secret.dynatrace_tokens
      │   │       reads from: aws_secretsmanager_secret.dynatrace_tokens (data source)
      │   │       creates: k8s secret "dynakube" in namespace "dynatrace"
      │   └─ kubectl_manifest.dynakube  (or kubernetes_manifest)
      │           CRD registered by helm_release.dynatrace_operator
      │           depends_on: helm_release.dynatrace_operator (CRD must exist first)
      │
      ├─ 5. helm_release.easytrade  ◄── REMOVED in this milestone
      │
      ├─ 5-NEW. ArgoCD Application CR (applied via Terraform kubernetes_manifest)
      │   └─ kubernetes_manifest.argocd_app_easytrade
      │           reads: gitops/apps/easytrade/Application.yaml (inline or file())
      │           depends_on: helm_release.argocd
      │           effect: ArgoCD queues first sync of EasyTrade from gitops/
      │
      └─ 6. kubernetes_ingress_v1.easytrade_ingress
              depends_on: [module.eks_blueprints_addons, helm_release.argocd]
              NOTE: ArgoCD now creates the namespace; ingress depends on app sync
              RISK: ingress must wait for ArgoCD to deploy the namespace+service
```

### Runtime Data Flow (Post-Cutover)

```
Developer workflow:
  edit gitops/apps/easytrade/values.yaml
       │
       ▼
  git push → GitHub
       │
       ▼
  ArgoCD (running in-cluster) polls repo every 3 min
  OR webhook-triggered (future)
       │
       ▼
  ArgoCD diffs desired state (gitops/) vs live cluster
       │
  ┌────┴───────────────────────────────────────────┐
  │  If diff exists:                               │
  │  ArgoCD reconciles → helm upgrade easytrade    │
  │  in namespace easytrade                        │
  └────────────────────────────────────────────────┘
       │
       ▼
  Pods updated rolling → ALB health checks pass
       │
       ▼
  Dynatrace Operator detects pod churn
  → OneAgent injects into new pods
  → traces/metrics/logs flow to DT tenant

Terraform apply (infra changes only):
  terraform apply → changes cluster / RDS / addons
  ArgoCD state: unaffected (app not re-deployed)
  ArgoCD reconciles naturally on next polling interval
```

---

## Component Boundaries

| Component | Owner | Responsibility | Communicates With |
|-----------|-------|---------------|-------------------|
| S3 bucket + DynamoDB table | Terraform (bootstrap) | State storage + locking | `terraform init` reads/writes |
| `main.tf` terraform backend block | Terraform | Points tfstate at S3 | S3 via AWS SDK |
| `module.eks` | Terraform | EKS control plane, node group, IRSA OIDC | Outputs cluster_name, endpoint, SG ids |
| `module.eks_blueprints_addons` | Terraform | AWS LB Controller only | Depends on module.eks outputs |
| RDS `aws_db_instance` | Terraform | Postgres for AccountService | Private subnets, rds_sg → node SG |
| `aws_secretsmanager_secret` (RDS) | Terraform | Stores RDS credentials | EKS pods (via volume mount or ESO) |
| `helm_release.argocd` | Terraform | Installs ArgoCD into `argocd` namespace | Depends on LB Controller (addon ordering) |
| `kubernetes_manifest.argocd_app_easytrade` | Terraform (one-time bootstrap) | Creates ArgoCD Application CR pointing at `gitops/` | ArgoCD reads this CR, reconciles EasyTrade |
| `helm_release.dynatrace_operator` | Terraform | Installs DT Operator CRDs + controller | Depends on provider auth (cluster must exist) |
| `kubernetes_secret.dynatrace_tokens` | Terraform | Pushes DT tokens into cluster as k8s Secret | Created before `kubectl_manifest.dynakube` |
| `kubectl_manifest.dynakube` (DynaKube CR) | Terraform | Activates DT monitoring mode | Depends on dynatrace_operator helm release |
| `gitops/apps/easytrade/Application.yaml` | Git / ArgoCD | Declares EasyTrade desired state | ArgoCD polls this from repo |
| `gitops/apps/easytrade/values.yaml` | Git / ArgoCD | Helm values for EasyTrade | Sourced by Application.yaml |
| ArgoCD Application controller | In-cluster (ArgoCD) | Reconciles gitops/ → cluster | EasyTrade namespace, Helm chart OCI registry |
| Dynatrace OneAgent (injected) | DT Operator (in-cluster) | Pod-level instrumentation | DT SaaS tenant via HTTPS |
| `kubernetes_ingress_v1.easytrade_ingress` | Terraform | ALB ingress for EasyTrade | ALB Controller, easytrade namespace Service |

---

## 1. Terraform Backend Migration Architecture

### The Bootstrap Problem

The S3 bucket and DynamoDB table cannot be managed inside the same `main.tf` that uses them as the backend — Terraform would need the backend to already exist to plan the resources that create the backend (chicken-and-egg). The chosen pattern for this lab:

**Recommended: Separate bootstrap apply, then migrate**

```
Step 1: Temporary local apply (no backend block yet)
  - Add a new bootstrap section to main.tf (or a one-off bootstrap.tf)
  - Resources: aws_s3_bucket, aws_s3_bucket_versioning,
               aws_s3_bucket_server_side_encryption_configuration,
               aws_dynamodb_table
  - terraform apply (state lands in local terraform.tfstate — that's fine, it's bootstrap)

Step 2: Add backend block to main.tf terraform{}
  terraform {
    backend "s3" {
      bucket         = "eks-trade-tfstate-<account_id>"
      key            = "easytrade-lab/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "terraform-locks"
    }
  }

Step 3: Migrate
  terraform init -migrate-state
  # Terraform detects backend change, prompts: "copy existing state to new backend?" → yes
  # Reads terraform.tfstate (local), writes to S3, sets up DynamoDB lock entry
  # Local terraform.tfstate becomes stale — back it up, then delete or .gitignore

Step 4: Verify
  terraform plan  # should show no changes; state now live in S3
```

### The OneDrive Interaction

The migration must be run from a location where Terraform can write the local state file one final time during `terraform init -migrate-state`. If OneDrive has enforced read-only permissions (`dr-xr-xr-x`), the migration will fail writing temporary files. The required sequence:

```
1. chmod u+w /path/to/EKS-Trade  (one-time fix)
2. Optionally cp -r EKS-Trade /tmp/eks-trade-migration && cd /tmp/eks-trade-migration
   (safer: work from a non-OneDrive copy during migration; OneDrive sync cannot corrupt /tmp)
3. Run terraform init -migrate-state from the non-OneDrive path
4. After successful migration, move project permanently out of OneDrive
5. The S3 backend is then the canonical state; OneDrive is no longer in the loop
```

After migration, the local `terraform.tfstate` files become dead weight — they must be added to `.gitignore` and eventually deleted, as S3 is now the single source of truth.

### Bootstrap Resource Placement

The S3 bucket and DynamoDB table should NOT live in `main.tf` long-term (they would create circular bootstrap issues on a fresh `terraform init` against a new S3 backend). Two clean approaches:

- **Option A (recommended for lab):** Create bucket and table once via AWS CLI commands, then add the backend block, then migrate. Simplest — no Terraform manages the backend resources themselves.
- **Option B:** A standalone `bootstrap/` subdirectory with its own Terraform root (separate state), run once. More maintainable for teams.

For this single-operator lab, Option A (CLI creation) is the lowest ceremony path.

---

## 2. RDS Architecture

### Placement in main.tf

Insert as **section 3.5** between the cluster (section 3) and blueprints addons (section 4). The RDS instance needs the cluster's node security group ID to write the ingress rule — which means it depends on `module.eks`. The addon section has no dependency on RDS, so the ordering is clean.

```
# --- 3.5. AccountService RDS (פיילוט PostgreSQL) ---
```

If `main.tf` grows unwieldy, a cleaner split into `db.tf` is acceptable — but keep the same numbered section comment banner in both files for navigation consistency.

### Network and Security Group Topology

```
  Private Subnets (np-lab-Private-*)
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │  EKS Node Group SG (module.eks.node_security_group_id)
  │         │                                           │
  │         │  allows outbound :5432                    │
  │         ▼                                           │
  │  aws_security_group.rds_sg                          │
  │         ingress: port 5432 from node SG             │
  │         egress: none (RDS initiates nothing)        │
  │         │                                           │
  │         ▼                                           │
  │  aws_db_instance.accountservice                     │
  │         engine: postgres                            │
  │         instance_class: db.t4g.micro                │
  │         multi_az: false                             │
  │         publicly_accessible: false                  │
  │         db_subnet_group: private subnets            │
  │                                                     │
  └─────────────────────────────────────────────────────┘
```

Key Terraform resources:
```hcl
resource "aws_db_subnet_group" "accountservice" {
  subnet_ids = data.aws_subnets.private.ids
}

resource "aws_security_group" "rds_sg" {
  vpc_id = data.aws_vpc.existing.id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "aws_db_instance" "accountservice" {
  identifier        = "accountservice-db"
  engine            = "postgres"
  instance_class    = "db.t4g.micro"
  multi_az          = false
  publicly_accessible = false
  db_subnet_group_name = aws_db_subnet_group.accountservice.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  # password via random_password or directly set (then stored in Secrets Manager)
}
```

### Secrets Strategy for Lab

**Recommended for this lab: Terraform creates the Secret, app consumes via Kubernetes Secret (created by Terraform).**

The full secrets-store-csi-driver stack (IRSA + SecretProviderClass + volume mounts) is production-grade but heavy for a lab pilot. The simpler path that still avoids plaintext in Git:

```
Terraform:
  1. aws_secretsmanager_secret "rds_accountservice" → stores JSON {host, port, user, pass}
  2. kubernetes_secret "accountservice-db" in namespace easytrade
       → reads from aws_secretsmanager_secret data source during apply
       → creates k8s Secret with DB_HOST, DB_PORT, DB_USER, DB_PASS

EasyTrade Helm (values.yaml in gitops/):
  accountService:
    env:
      DB_HOST:
        secretKeyRef:
          name: accountservice-db
          key: host
      # ...etc
```

This means DB credentials are in Terraform state (S3, encrypted) and in the k8s etcd (cluster-encrypted). Not ideal for production but acceptable for a lab where S3 state is now encrypted at rest. The alternative (secrets-store-csi-driver) adds an IRSA role + SecretProviderClass CR + volume mount — worth doing in a follow-on milestone if the pattern needs hardening.

---

## 3. ArgoCD Architecture

### Installation Position in Apply Order

ArgoCD is a cluster-level addon — it must come AFTER `module.eks_blueprints_addons` (ALB Controller needs to be up first so the ArgoCD UI can eventually get an ALB if needed, and more importantly because the blueprints module configures IAM that ArgoCD's CRD installation may reference).

Position: **section 4.5** in `main.tf`.

```hcl
# --- 4.5. ArgoCD (GitOps Controller) ---
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.x.x"  # pin a version
  namespace        = "argocd"
  create_namespace = true

  depends_on = [module.eks_blueprints_addons]
}
```

### Gitops/ Repo Layout

```
EKS-Trade/                              ← repo root (same repo, monorepo)
├── main.tf
├── .gitignore
├── .terraform.lock.hcl
└── gitops/                             ← ArgoCD source root
    └── apps/
        ├── root/
        │   └── Application.yaml       ← (optional) App-of-Apps root; points at gitops/apps/
        └── easytrade/
            ├── Application.yaml       ← ArgoCD Application CR
            └── values.yaml            ← Helm values (chart version pinned here)
```

**gitops/apps/easytrade/Application.yaml:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: easytrade
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/<your-org>/EKS-Trade.git
    targetRevision: HEAD
    path: gitops/apps/easytrade
    helm:
      valueFiles:
        - values.yaml
      # chart sourced from OCI — use chart field:
      chart: easytrade
      repoURL: oci://europe-docker.pkg.dev/dynatrace-demoability/helm
      targetRevision: "1.X.Y"   # PIN the version here — fixes the existing concern
  destination:
    server: https://kubernetes.default.svc
    namespace: easytrade
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Note: ArgoCD supports OCI Helm chart sources directly from ArgoCD v2.6+. The `source.chart` + `source.repoURL` (OCI) combination sources the chart from the OCI registry, while `path` in the same Application.yaml (a different source) can point to the values file in Git. From ArgoCD v2.6, multiple sources per Application are supported — use this to separate the OCI chart from the Git values file.

### App-of-Apps (Optional for this milestone)

For a single app, a root App-of-Apps is optional overhead. Skip it for this milestone. If a second app is added later, introduce `gitops/apps/root/Application.yaml` at that point.

---

## 4. ArgoCD Cutover: The Transitional State

This is the most critical architectural moment — describing exactly what happens when `helm_release.easytrade` is removed and ArgoCD takes over.

### Pre-Cutover State

```
Cluster state:
  namespace/easytrade EXISTS (created by helm_release.easytrade)
  helm release "easytrade" tracked by Terraform state
  ~12 EasyTrade pods running, ALB serving traffic
  kubernetes_ingress_v1.easytrade_ingress exists (Terraform-owned)
```

### Cutover Sequence

**Step 1: Add ArgoCD (Terraform apply — additive)**
```
terraform apply
  + helm_release.argocd  → ArgoCD running in argocd namespace
  (helm_release.easytrade still present, no change to EasyTrade)
```

**Step 2: Add Application CR to gitops/ AND to Terraform**

Add `gitops/apps/easytrade/Application.yaml` to the repo (git commit, do NOT yet trigger auto-sync — set `syncPolicy.automated` off initially, or use manual sync trigger).

Also add to `main.tf`:
```hcl
resource "kubernetes_manifest" "argocd_app_easytrade" {
  manifest = yamldecode(file("${path.module}/gitops/apps/easytrade/Application.yaml"))
  depends_on = [helm_release.argocd]
}
```

**Step 3: Remove helm_release.easytrade from main.tf**

In the same `terraform apply` as Step 2 (or a separate apply — separate is safer):

```
terraform apply
  - helm_release.easytrade  → Terraform will DESTROY the Helm release
    This means: helm uninstall easytrade → pods terminated, namespace DELETED
  + kubernetes_manifest.argocd_app_easytrade → ArgoCD Application CR created
```

**CRITICAL DOWNTIME WINDOW:** When Terraform destroys `helm_release.easytrade`, it runs `helm uninstall`, which deletes all resources in the release including pods and by default the namespace. There is a brief outage here. This is unavoidable unless an alternative adoption path is used.

**Alternative: Zero-Downtime Adoption via ArgoCD**

To avoid downtime, use ArgoCD's adopt-in-place approach BEFORE removing from Terraform:

```
Step A: Create Application.yaml with syncPolicy.automated disabled
        (ArgoCD sees the app but does not sync yet)

Step B: In Terraform, add lifecycle { prevent_destroy = true } to
        helm_release.easytrade temporarily, to prevent accidental destroy

Step C: Remove helm_release.easytrade from Terraform state only:
        terraform state rm helm_release.easytrade
        (This drops Terraform's tracking, does NOT run helm uninstall)
        The Helm release and all pods remain running.

Step D: Remove the resource block from main.tf
        (terraform plan now shows nothing to destroy — resource was state-rm'd)

Step E: In ArgoCD UI or CLI, trigger a manual sync for the easytrade Application
        ArgoCD adds tracking annotations to existing resources
        No pods restart, no namespace recreation (verified: ArgoCD adoption is non-destructive
        for standard Helm charts without checksum mechanisms)

Step F: Enable automated sync in Application.yaml, commit, push
        ArgoCD is now the owner; git push drives future changes
```

**Recommended: Step C (`terraform state rm`) approach** — preserves pod continuity, avoids the helm uninstall/reinstall cycle, keeps the ALB stable throughout. This is the zero-downtime path.

### Post-Cutover State

```
Cluster state:
  namespace/easytrade EXISTS (now ArgoCD-owned)
  ArgoCD Application "easytrade" in Sync + Healthy
  All pods running (no restart occurred)
  kubernetes_ingress_v1.easytrade_ingress still Terraform-owned (no change)
  Helm release "easytrade" exists in cluster (managed by ArgoCD going forward)

Terraform state:
  helm_release.easytrade ABSENT (was state rm'd or never in this apply)
  kubernetes_manifest.argocd_app_easytrade PRESENT

Git state:
  gitops/apps/easytrade/Application.yaml committed
  gitops/apps/easytrade/values.yaml committed (with pinned chart version)
```

### The Ingress Contract Post-Cutover

`kubernetes_ingress_v1.easytrade_ingress` remains Terraform-owned. It references `easytrade-frontendreverseproxy` service. As long as ArgoCD deploys the same chart (which creates that service), the ingress contract holds. The ingress is safe to remain Terraform-owned for this milestone — moving it into `gitops/` is a future improvement.

The missing `depends_on` on the ingress resource (existing concern) should be fixed at cutover time:
```hcl
depends_on = [
  module.eks_blueprints_addons,          # ALB controller ready
  kubernetes_manifest.argocd_app_easytrade,  # ArgoCD has queued the sync
]
```
This does not guarantee ArgoCD sync completes before the ingress is applied (ArgoCD sync is async), but it ensures ArgoCD is at least bootstrapped and the Application CR exists.

---

## 5. Dynatrace Operator Architecture

### Install via Terraform (not ArgoCD)

Per the project's key decision: Dynatrace Operator is cluster-level infrastructure, installed via Terraform Helm like the ALB Controller. This is correct because:

1. The Operator must exist before ArgoCD syncs app workloads (so OneAgent can inject at pod start)
2. Operator tokens are managed via Secrets Manager → k8s Secret → DynaKube CR (all Terraform-owned resources)
3. No benefit to ArgoCD owning the Operator for this single-tenant lab

Position: **section 4.6** in `main.tf`, after ArgoCD.

```
# --- 4.6. Dynatrace Operator (צפייה ב-Cluster) ---
```

### Deployment Sequence Within Terraform

```
helm_release.dynatrace_operator (installs CRDs + controller)
         │
         ▼  (depends_on)
kubernetes_namespace.dynatrace
         │
         ▼  (depends_on)
kubernetes_secret.dynatrace_tokens
  (reads from aws_secretsmanager_secret.dynatrace_tokens data source)
  (creates k8s secret "dynakube" in namespace "dynatrace" with apiToken + dataIngestToken)
         │
         ▼  (depends_on)
kubernetes_manifest.dynakube
  (applies DynaKube CR — activates monitoring mode)
  (MUST come after CRDs are registered; CRD registration takes ~10-30s after helm deploy)
```

The CRD timing risk is real: the DynaKube CRD is registered by the Helm chart but takes seconds to propagate. The `kubernetes_manifest` resource will fail if the CRD is not yet registered. Mitigation: add `depends_on = [helm_release.dynatrace_operator]` and accept a possible first-apply failure, re-run `terraform apply` to converge. Alternatively, use a `time_sleep` resource (10-30s) between the helm release and the manifest — explicit and reliable for a lab.

### DynaKube CR Pattern

```yaml
# Inline in kubernetes_manifest or sourced from file
apiVersion: dynatrace.com/v1beta1
kind: DynaKube
metadata:
  name: dynakube
  namespace: dynatrace
spec:
  apiUrl: https://<tenant>.live.dynatrace.com/api
  tokens: dynakube          # matches the k8s Secret name
  oneAgent:
    cloudNativeFullStack:
      tolerations:
        - effect: NoSchedule
          key: node-role.kubernetes.io/master
          operator: Exists
```

The `tokens: dynakube` references the Kubernetes Secret named `dynakube` in the `dynatrace` namespace, which Terraform creates from Secrets Manager.

---

## 6. Build Order and Phase Sequencing

### Dependency Graph

```
[AWS Account baseline]
         │
         ▼
[Phase 1] S3 bucket + DynamoDB table (bootstrap, one-time)
         │  enables: safe state for all subsequent phases
         ▼
[Phase 1 cont.] terraform init -migrate-state
                + EKS CIDR allow-list applied in same apply
         │
         ▼
[Phase 2] RDS section in main.tf
         │  requires: EKS node SG id (module.eks must exist)
         │  requires: private subnet ids (data.aws_subnets.private already present)
         ▼
[Phase 3] ArgoCD install (helm_release.argocd)
         │  requires: cluster running + provider auth
         │  requires: ALB controller (module.eks_blueprints_addons)
         │  produces: argocd namespace + Application controller
         ▼
[Phase 4] gitops/ folder + Application.yaml authored
         │  requires: ArgoCD running (so CR can be applied)
         │  requires: chart version pinned in values.yaml
         │  produces: EasyTrade owned by ArgoCD
         │
         ├─ terraform state rm helm_release.easytrade
         │   (zero-downtime cutover — no helm uninstall)
         │
         └─ kubernetes_manifest.argocd_app_easytrade applied
             ArgoCD adopts existing workload
         ▼
[Phase 5] Dynatrace Operator (helm_release + DynaKube CR)
         │  requires: cluster running + provider auth
         │  requires: Secrets Manager secret exists with DT tokens
         │            (tokens provisioned out-of-band from DT tenant UI)
         │  produces: OneAgent injected into all pods
         │  best applied AFTER EasyTrade is stable under ArgoCD
         │  so DT immediately sees a healthy app for baselining
         ▼
[Phase 6] Validation
         - EasyTrade reachable via ALB
         - ArgoCD shows Synced + Healthy
         - DT tenant shows services, traces, host metrics
         - terraform plan shows no changes
         - git push to gitops/ triggers ArgoCD reconcile (no terraform needed)
```

### Rationale for This Order

| Phase | Why Here |
|-------|----------|
| Backend first | Every subsequent apply writes to state; OneDrive corruption risk is eliminated before any new resources are added |
| CIDR allow-list bundled with backend | Both are low-risk cluster config changes; combining avoids an extra apply window |
| RDS before ArgoCD | RDS credentials and the Kubernetes Secret must exist in the cluster before the ArgoCD-managed EasyTrade tries to use them; installing ArgoCD first and then RDS would cause EasyTrade's AccountService to fail on first sync |
| ArgoCD before gitops/ | ArgoCD must be running before the Application CR can be applied |
| Dynatrace last | OneAgent injection requires pod restart (for existing pods); doing DT after EasyTrade is stable under ArgoCD means one controlled rollout cycle, not two |

---

## Recommended Repo Layout (Post-Milestone)

```
EKS-Trade/
├── main.tf                              ← Terraform root (sections 1-7, minus section 5)
├── .terraform.lock.hcl
├── .gitignore                           ← ADDED: excludes *.tfstate, .terraform/, *.tfvars
├── gitops/                              ← NEW: ArgoCD source tree
│   └── apps/
│       └── easytrade/
│           ├── Application.yaml         ← ArgoCD Application CR (OCI chart + Git values)
│           └── values.yaml             ← EasyTrade helm values (chart version PINNED)
└── .planning/                          ← workflow documentation
    └── ...
```

The `gitops/` folder sits at repo root so the ArgoCD `path:` reference is unambiguous (`gitops/apps/easytrade`). The Application CR itself lives under `gitops/` so ArgoCD manages its own source — if a root App-of-Apps is introduced later, it simply points to `gitops/apps/` and discovers child Applications automatically.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Creating S3 Bucket Inside the Same Backend Config Root

**What people do:** Add `aws_s3_bucket` to `main.tf`, add `backend "s3"` pointing at it, then run `terraform init`.

**Why it fails:** `terraform init` tries to initialize the backend (connect to S3) before `terraform apply` can create the bucket. Circular dependency — Terraform errors with "bucket does not exist".

**Do this instead:** CLI-create the bucket first (one-time), then add backend block, then `terraform init -migrate-state`.

### Anti-Pattern 2: Removing helm_release.easytrade Without State RM First

**What people do:** Delete the `helm_release.easytrade` block from `main.tf`, run `terraform apply`.

**Why it's wrong:** Terraform runs `helm uninstall easytrade`, which terminates all EasyTrade pods and deletes the namespace. If ArgoCD hasn't fully adopted the workload yet, there's both an outage and a sync race.

**Do this instead:** `terraform state rm helm_release.easytrade` first. Removes Terraform tracking without touching the running Helm release. Then delete the block from `main.tf`. Then adopt via ArgoCD.

### Anti-Pattern 3: Applying DynaKube CR Without Waiting for CRD Registration

**What people do:** Add `kubernetes_manifest.dynakube` with `depends_on = [helm_release.dynatrace_operator]`, expect it to work on first apply.

**Why it fails:** Helm marks the release as deployed when charts are applied, but CRDs take additional seconds to be accepted by the API server. `kubernetes_manifest` immediately tries to create the DynaKube resource against an API server that doesn't yet know the CRD.

**Do this instead:** Add a `time_sleep` resource (20-30s) between the helm release and the manifest, OR accept the first-apply failure and re-run `terraform apply` (idempotent, will succeed on retry).

### Anti-Pattern 4: Leaving Ingress depends_on Empty Through the Cutover

**What people do:** Keep the empty `depends_on = []` on `kubernetes_ingress_v1.easytrade_ingress` during the ArgoCD cutover.

**Why it's wrong:** After cutover, the easytrade namespace and `easytrade-frontendreverseproxy` Service are created by ArgoCD (async). The Terraform ingress resource may apply before ArgoCD completes its first sync, causing the ingress to reference a non-existent Service. The ALB controller will still create the ALB but health checks will fail until ArgoCD finishes.

**Do this instead:** At cutover, update `depends_on` to include `kubernetes_manifest.argocd_app_easytrade`. This doesn't guarantee ArgoCD sync completes (ArgoCD is async) but ensures the Application CR exists. Accept that the first post-cutover plan/apply may need ArgoCD to finish before the ALB goes healthy.

---

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| AWS Secrets Manager | Terraform data source reads secrets at apply time → creates k8s Secret | DT tokens manually seeded into SM before DT phase |
| OCI Helm Registry (GCR) | ArgoCD sources EasyTrade chart directly from `oci://europe-docker.pkg.dev/...` | Requires EKS node internet egress (already present via NAT) |
| Dynatrace SaaS tenant | DynaKube CR's `apiUrl` + tokens → OneAgent connects outbound HTTPS | Tokens generated in DT tenant UI, stored in Secrets Manager |
| GitHub (this repo) | ArgoCD polls `repoURL` for gitops/ changes | Public repo: no credentials needed. Private repo: needs ArgoCD secret |

### Internal Boundaries (Post-Milestone)

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Terraform → ArgoCD | `kubernetes_manifest` creates Application CR | One-time bootstrap only |
| ArgoCD → EasyTrade | Helm chart sync from OCI + values from gitops/ | Ongoing; git push drives this |
| EasyTrade AccountService → RDS | TCP 5432 via SG rule, credentials from k8s Secret | Static secret (lab); rotation deferred |
| DT Operator → EasyTrade pods | Webhook injection at pod admission | All pods in instrumented namespaces get OneAgent |
| Ingress → EasyTrade Service | kubernetes_ingress_v1 → ALB → easytrade-frontendreverseproxy:8080 | Ingress remains Terraform-owned |

---

## Sources

- ArgoCD sync options and adoption behavior: https://www.aviator.co/blog/how-to-onboard-an-existing-helm-application-in-argocd/
- ArgoCD sync options (official): https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/
- ArgoCD Application specification (official): https://argo-cd.readthedocs.io/en/stable/user-guide/application-specification/
- Dynatrace GitOps deployment guide (official): https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/guides/deployment-and-configuration/using-gitops
- Dynatrace Operator Helm chart: https://artifacthub.io/packages/helm/dynatrace/dynatrace-operator
- Terraform S3 backend migration: https://support.hashicorp.com/hc/en-us/articles/44027197997587-How-to-Migrate-Terraform-State-Between-Different-Backends-using-init-migrate-state
- Terraform bootstrap patterns: https://burakdede.com/blog/the-terraform-bootstrap-problem-how-to-create-your-state-backend-without-going-insane/
- AWS Secrets Store CSI Driver for EKS: https://docs.aws.amazon.com/eks/latest/userguide/manage-secrets.html
- EKS Blueprints ArgoCD addon: https://aws-ia.github.io/terraform-aws-eks-blueprints-addons/main/addons/argocd/
- RDS + EKS SG pattern: https://registry.terraform.io/modules/terraform-aws-modules/rds/aws/latest

---

*Architecture research for: AWS EKS hardening — Terraform backend + RDS + ArgoCD + Dynatrace Operator*
*Researched: 2026-04-20*
