# Requirements: EKS-Trade

**Defined:** 2026-04-20
**Core Value:** EasyTrade stays reachable via the ALB and fully observable in Dynatrace, with deployments safely reproducible from Git.

## v1 Requirements

Requirements for the hardening milestone. Each maps to a roadmap phase. Derived from PROJECT.md Active list and research/SUMMARY.md phase breakdown.

### State & Security

- [ ] **STATE-01**: Terraform state lives in an S3 bucket (versioning on, SSE-S3 AES256, public-access block on, bucket policy deny-non-TLS)
- [ ] **STATE-02**: Terraform state writes are locked (S3-native `use_lockfile = true` when CLI ≥ 1.10; DynamoDB fallback otherwise)
- [ ] **STATE-03**: `terraform init -migrate-state` completed; `terraform plan` produces zero diff against remote state
- [ ] **STATE-04**: Local `terraform.tfstate*` files are deleted from the working directory
- [ ] **STATE-05**: `.gitignore` excludes `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars`, `*.auto.tfvars` before first commit
- [ ] **SEC-01**: EKS API `cluster_endpoint_public_access_cidrs` is set to an explicit office/VPN allow-list; `0.0.0.0/0` removed

### RDS (Pilot)

- [ ] **RDS-01**: RDS Postgres 17 instance provisioned via `terraform-aws-modules/rds/aws ~> 6.10` in the existing `np-lab` private subnets
- [ ] **RDS-02**: Instance class `db.t4g.micro`, Single-AZ; `storage_encrypted = true`; 7-day automated backups
- [ ] **RDS-03**: Security group allows inbound 5432 **only** from `module.eks.node_security_group_id` (no CIDR-based rules)
- [ ] **RDS-04**: `publicly_accessible = false`; `deletion_protection = true`; Terraform `lifecycle { prevent_destroy = true }`
- [ ] **RDS-05**: `manage_master_user_password = true` — credentials in AWS Secrets Manager; automatic rotation explicitly **disabled** for the lab
- [ ] **RDS-06**: Kubernetes `Secret` materialized in `easytrade` namespace from Secrets Manager at apply time; consumable by AccountService
- [ ] **RDS-07**: AccountService (EasyTrade) runs against the RDS instance end-to-end — app responds 200 on its health path after cutover
- [ ] **RDS-08**: CloudWatch alarm on `CPUCreditBalance` for the RDS instance (t-family burst credit early warning)

### GitOps (ArgoCD + EasyTrade Cutover)

- [ ] **GITOPS-01**: ArgoCD installed via `helm_release` (`argo/argo-cd` chart `9.5.2`) with `wait = true`
- [ ] **GITOPS-02**: `argo/argocd-apps` companion chart `2.0.4` installed with `depends_on = [helm_release.argocd]`; ApplicationSet with Git directory generator pointed at `gitops/apps/*`
- [ ] **GITOPS-03**: `gitops/apps/easytrade/Application.yaml` + `values.yaml` committed; EasyTrade Helm chart **version pinned** (not `HEAD`); `targetRevision: main`
- [ ] **GITOPS-04**: Pre-cutover: Helm release secret (`-l owner=helm,name=easytrade`) deleted from `easytrade` namespace
- [ ] **GITOPS-05**: `terraform state rm helm_release.easytrade` executed before the ArgoCD Application is activated — the zero-downtime path
- [ ] **GITOPS-06**: `helm_release.easytrade` block removed from `main.tf`; `terraform plan` produces zero diff against remote state
- [ ] **GITOPS-07**: ArgoCD Application reports `Synced` + `Healthy` for EasyTrade; ALB continues serving traffic throughout the cutover (no 5xx window)
- [ ] **GITOPS-08**: `syncPolicy.automated.prune: false` during first sync; enabled to `true` only after Synced + Healthy is manually verified
- [ ] **GITOPS-09**: `kubernetes_ingress_v1.easytrade_ingress.depends_on` populated with `[module.eks_blueprints_addons]` (closes Medium-severity concern from CONCERNS.md)

### Observability (Dynatrace Operator)

- [ ] **OBS-01**: Operator tokens (`apiToken` + `dataIngestToken`) generated via Dynatrace UI "Kubernetes: Dynatrace Operator" token wizard and provided via `TF_VAR_*` env vars (never in `.tfvars`, never committed)
- [ ] **OBS-02**: Pre-apply egress check: pod in cluster can `curl https://<tenant-id>.live.dynatrace.com/api/v1/time` → 200
- [ ] **OBS-03**: Dynatrace Operator OCI chart `1.9.0` (`oci://public.ecr.aws/dynatrace/dynatrace-operator`) installed in `dynatrace` namespace via Terraform Helm; `wait = true`, `timeout = 300`, `atomic = true`
- [ ] **OBS-04**: `kubernetes_secret.dynakube_tokens` created in `dynatrace` namespace from the TF_VAR-provided tokens
- [ ] **OBS-05**: `DynaKube` CR deployed in `cloudNativeFullStack` mode; `namespaceSelector` scoped to `easytrade` namespace only (not kube-system, not argocd, not dynatrace itself); `spec.apiUrl = https://<tenant-id>.live.dynatrace.com/api`
- [ ] **OBS-06**: ActiveGate configured with `kubernetes-monitoring` + `routing` capabilities
- [ ] **OBS-07**: `kubectl describe dynakube -n dynatrace` shows all conditions `True` within 5 minutes of apply
- [ ] **OBS-08**: EasyTrade services visible in the Dynatrace tenant — traces, host/pod metrics, and container logs flowing end-to-end

## v2 Requirements

Deferred. Tracked but not in this milestone.

### RDS

- **RDS-V2-01**: IAM database authentication for RDS
- **RDS-V2-02**: Performance Insights + Enhanced Monitoring
- **RDS-V2-03**: Replicate pattern to remaining Postgres-backed EasyTrade services (OfferService, PlaidService, etc.)
- **RDS-V2-04**: Externalize MSSQL-backed EasyTrade services via RDS SQL Server Express

### GitOps

- **GITOPS-V2-01**: Git webhook for fast ArgoCD sync
- **GITOPS-V2-02**: ApplicationSet managing additional workloads beyond EasyTrade
- **GITOPS-V2-03**: SSO via OIDC for ArgoCD UI (replace admin-password-only access)
- **GITOPS-V2-04**: Project-scoped RBAC policies

### Observability

- **OBS-V2-01**: RUM injection into EasyTrade frontend
- **OBS-V2-02**: Prometheus scrape via Dynatrace (for any non-OneAgent workloads)
- **OBS-V2-03**: Log ingestion tuning / Grail cost governance
- **OBS-V2-04**: Synthetic monitors for the EasyTrade ALB hostname

### Secrets

- **SEC-V2-01**: External Secrets Operator or Secrets Store CSI Driver for runtime secret injection with rotation
- **SEC-V2-02**: Automatic credential rotation for RDS (paired with app-side credential refresh)

### Infra hardening

- **INFRA-V2-01**: Private-only EKS endpoint (VPN/bastion access); close the public endpoint entirely
- **INFRA-V2-02**: Extract hardcoded region / VPC id / cluster name / k8s version to variables
- **INFRA-V2-03**: Manage `vpc-cni`, `coredns`, `aws-ebs-csi-driver`, `eks-pod-identity-agent` via `cluster_addons`
- **INFRA-V2-04**: On-demand secondary node group for non-SPOT workload placement

## Out of Scope

| Feature | Reason |
|---|---|
| Multi-AZ / HA RDS | Explicit lab cost posture; Single-AZ `db.t4g.micro` is the chosen sizing |
| Read replicas, RDS Proxy | Lab has no multi-reader workload; would mask RDS pilot as "too production-like" |
| Migrating MSSQL-backed EasyTrade services | Pilot is Postgres-only (AccountService); MSSQL evaluation belongs in a later milestone |
| External-dns / Route 53 automation | ALB DNS name is the only record consumed; operator uses `alb_check_command` output |
| Cert-manager | Dynatrace Operator has its own CSI-based webhook certs; no other workload needs cert-manager this milestone |
| kube-prometheus-stack / Grafana | Dynatrace is the chosen observability vendor; stacking Prometheus adds cost and redundancy |
| Karpenter | Managed node group is sufficient for a lab; Karpenter interacts poorly with `classicFullStack` (we use `cloudNativeFullStack` anyway) |
| Argo Rollouts, Argo Image Updater, Dex SSO | Over-kit for a single-user lab |
| Multi-cluster ArgoCD | Single-cluster lab |
| Separate GitOps repo (polyrepo) | Chose monorepo — one repo to reason about |
| Full productization (workspaces, env overlays, CI/CD) | Explicitly deferred — this milestone is "hardening", not "productizing" |
| Replacing the existing `np-lab` VPC | Stack continues to adopt the existing VPC by id |
| Moving IRSA → Pod Identity | Acceptable as-is; not part of the four hardening goals |
| Loadgen (`loadgen.enabled`) | Stays off; external traffic drives the demo |
| Session replay, synthetic monitors | Not part of the "Dynatrace Operator observability" scope |

## Traceability

Filled during roadmap creation.

| Requirement | Phase | Status |
|---|---|---|
| STATE-01 | — | Pending |
| STATE-02 | — | Pending |
| STATE-03 | — | Pending |
| STATE-04 | — | Pending |
| STATE-05 | — | Pending |
| SEC-01 | — | Pending |
| RDS-01 | — | Pending |
| RDS-02 | — | Pending |
| RDS-03 | — | Pending |
| RDS-04 | — | Pending |
| RDS-05 | — | Pending |
| RDS-06 | — | Pending |
| RDS-07 | — | Pending |
| RDS-08 | — | Pending |
| GITOPS-01 | — | Pending |
| GITOPS-02 | — | Pending |
| GITOPS-03 | — | Pending |
| GITOPS-04 | — | Pending |
| GITOPS-05 | — | Pending |
| GITOPS-06 | — | Pending |
| GITOPS-07 | — | Pending |
| GITOPS-08 | — | Pending |
| GITOPS-09 | — | Pending |
| OBS-01 | — | Pending |
| OBS-02 | — | Pending |
| OBS-03 | — | Pending |
| OBS-04 | — | Pending |
| OBS-05 | — | Pending |
| OBS-06 | — | Pending |
| OBS-07 | — | Pending |
| OBS-08 | — | Pending |

**Coverage:**
- v1 requirements: 31 total
- Mapped to phases: 0 (roadmap not yet created)
- Unmapped: 31 ⚠️ (expected — updated after roadmap)

---
*Requirements defined: 2026-04-20*
*Last updated: 2026-04-20 after initial definition*
