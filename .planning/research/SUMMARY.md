# Project Research Summary

**Project:** EKS-Trade — Lab Hardening Milestone
**Domain:** AWS EKS infrastructure hardening — S3 Terraform backend, RDS Postgres pilot, ArgoCD GitOps cutover, Dynatrace Operator observability
**Researched:** 2026-04-20
**Confidence:** HIGH

---

## Executive Summary

This milestone hardens an existing single-file Terraform EKS lab that runs the Dynatrace EasyTrade demo. The four capabilities are additive and strictly sequenced: safe state storage must come first, RDS must exist before ArgoCD first syncs EasyTrade, and Dynatrace Operator should be applied after EasyTrade is stable under ArgoCD so OneAgent sees a healthy baseline immediately. The recommended approach keeps Terraform as the cluster infra owner (S3 backend, RDS, ArgoCD, Dynatrace Operator) and hands the EasyTrade application lifecycle cleanly to ArgoCD via a monorepo `gitops/` folder. Terraform's `main.tf` grows two new sections and loses the `helm_release.easytrade` block; a new top-level `gitops/` directory appears.

The single most critical operator action in the entire milestone is the ArgoCD cutover: `terraform state rm helm_release.easytrade` must be run before ArgoCD creates the Application CR, or Terraform will `helm uninstall` EasyTrade on the next apply, causing a downtime window and a sync race. Every other risk in this milestone is well-understood and preventable with explicit Terraform flags (`deletion_protection`, `publicly_accessible = false`, `wait = true`) or sequencing discipline. The Dynatrace Operator install carries two reliable failure modes — CRD registration timing and tenant URL format — both of which have deterministic mitigations.

The milestone is straightforward in scope but has several sharp edges: the Terraform CLI version must be verified before choosing between S3-native locking (`use_lockfile = true`, stable in 1.11+) and a DynamoDB fallback; the RDS module version must be held at `~> 6.10` (v7.x requires `aws >= 6.27`, incompatible with the locked `aws ~> 5.0` provider); and Secrets Manager automatic rotation must be explicitly disabled for the lab to prevent a silent 30-day credential break.

---

## Key Findings

### Recommended Stack

The locked provider set (`aws 5.100.0`, `kubernetes 2.38.0`, `helm 2.17.0`) is immovable this milestone. All new resources must fit within those constraints. The most important constraint is the RDS module: `terraform-aws-modules/rds/aws` v7.x requires `aws >= 6.27` and Terraform >= 1.11, making it incompatible with the existing lock — use `~> 6.10` only. All new Helm installs (ArgoCD, Dynatrace Operator) go through the existing `helm ~> 2.0` provider, which has stable OCI support since 2.9.x.

**Core technologies (new this milestone):**

- `terraform backend "s3"` with `use_lockfile = true` — eliminates OneDrive state corruption; forwards-compatible with Terraform 1.11+ native locking. Fallback to `dynamodb_table` if CLI is confirmed < 1.10 (verify at plan time).
- `terraform-aws-modules/rds/aws ~> 6.10` — last series compatible with `aws ~> 5.0`; wraps subnet group, parameter group, SG, and instance boilerplate. Do NOT use 7.x.
- PostgreSQL 17 on `db.t4g.micro`, Single-AZ, `manage_master_user_password = true` — password never appears in Terraform state; Secrets Manager ARN is the handoff point to EasyTrade.
- `argo/argo-cd` Helm chart `9.5.2` (ArgoCD v3.3.7) + `argo/argocd-apps` chart `2.0.4` — stable, Kubernetes 1.34-compatible; `wait = true` required so CRDs register before the companion chart applies ApplicationSet resources.
- `dynatrace-operator` OCI chart `1.9.0` from `oci://public.ecr.aws/dynatrace` — traditional Helm repo is deprecated; OCI is the current delivery mechanism; `cloudNativeFullStack` mode is correct for SPOT EKS nodes (webhook-based injection, no pod-restart-before-instrumentation race).
- Two Dynatrace tokens only: `apiToken` + `dataIngestToken` — `paasToken` is legacy and not required by Operator 1.x.
- `hashicorp/random 3.8.1` is already a transitive dependency; safe to reference if needed.

### Feature Scope by Phase (Table Stakes Only)

Differentiators and anti-features are recorded in FEATURES.md and deferred to v2+.

**Phase 1 — State Backend + CIDR Hardening:**
- S3 bucket with versioning, SSE-S3 encryption (AES256), and public-access block
- State locking via `use_lockfile = true` (DynamoDB fallback only if CLI < 1.10)
- `terraform init -migrate-state` executed once; local `*.tfstate*` files deleted and `.gitignore`d
- `cluster_endpoint_public_access_cidrs` set to office/VPN CIDR — removes `0.0.0.0/0`

**Phase 2 — RDS Postgres Pilot:**
- `db.t4g.micro` Single-AZ Postgres 17 in `np-lab-Private-*` subnets
- Security group: inbound 5432 from `module.eks.node_security_group_id` only (never a CIDR)
- `manage_master_user_password = true` — Secrets Manager holds credentials, never in state
- Automatic rotation explicitly disabled for the lab (prevents silent 30-day credential break)
- `kubernetes_secret` in `easytrade` namespace materialized from Secrets Manager at apply time — lab-grade wiring, no secrets-store-csi complexity
- `deletion_protection = true` on the instance; `lifecycle { prevent_destroy = true }` in Terraform

**Phase 3 — ArgoCD + EasyTrade GitOps Cutover:**
- `helm_release.argocd` (chart 9.5.2) with `wait = true`
- `helm_release.argocd_apps` (chart 2.0.4) with `depends_on = [helm_release.argocd]`
- ApplicationSet with Git directory generator pointed at `gitops/apps/*`
- `gitops/apps/easytrade/` committed with chart version pinned (discovered from `helm list -n easytrade` before cutover)
- **`terraform state rm helm_release.easytrade` run before Application CR is created** — the zero-downtime path; non-negotiable
- Helm release secret (`sh.helm.sh/chart`) deleted from `easytrade` namespace before ArgoCD takes ownership
- `syncPolicy.automated.prune: false` during initial cutover; enabled only after first sync validated manually
- `targetRevision: main` (not `HEAD`) — documented that any push to main triggers sync

**Phase 4 — Dynatrace Operator:**
- `dynatrace-operator` OCI chart `1.9.0` with `wait = true`, `timeout = 300`, `atomic = true`
- `kubernetes_secret.dynakube_tokens` in `dynatrace` namespace (tokens from `TF_VAR_*` env vars, never in `.tfvars`)
- `kubernetes_manifest.dynakube` with `cloudNativeFullStack` mode; `namespaceSelector` scoped to `easytrade` namespace only
- `apiUrl` set to `https://<tenant-id>.live.dynatrace.com/api` (not `apps.dynatrace.com`)
- ActiveGate with `kubernetes-monitoring` + `routing` capabilities
- Pre-install egress check: `curl` from a pod in the cluster to `<tenant>.live.dynatrace.com/api/v1/time` must return 200

**Deferred to v2+:**
- IAM database authentication for RDS
- External Secrets Operator / Secrets Store CSI Driver for runtime secret injection with rotation
- Git webhook for ArgoCD fast sync
- Performance Insights + Enhanced Monitoring on RDS
- RUM injection into EasyTrade frontend
- Prometheus scrape via Dynatrace
- ApplicationSets managing additional services beyond EasyTrade

### Architecture Approach

The milestone shifts the ownership boundary inside a flat `main.tf`. Terraform grows sections 3.5 (RDS), 4.5 (ArgoCD), and 4.6 (Dynatrace Operator); it loses section 5 (`helm_release.easytrade`). ArgoCD takes ownership of the application tier via a `kubernetes_manifest` bootstrap Application CR that points at `gitops/apps/easytrade/`. The `kubernetes_ingress_v1.easytrade_ingress` stays Terraform-owned this milestone. AWS Secrets Manager is the secrets handoff point between Terraform-provisioned infra (RDS credentials, Dynatrace tokens) and in-cluster consumers.

**Major components and responsibilities:**

| Component | Owner | Key Responsibility |
|---|---|---|
| S3 bucket + backend block | Terraform | Encrypted, versioned remote state; S3-native locking |
| `module.eks` | Terraform (unchanged) | EKS control plane, node group, IRSA OIDC; outputs node SG id |
| RDS + SG + Secrets Manager | Terraform | AccountService Postgres; credentials never in state |
| `kubernetes_secret` (RDS) | Terraform | Materializes RDS credentials into `easytrade` namespace at apply time |
| `helm_release.argocd` + `argocd_apps` | Terraform | Installs ArgoCD; bootstraps ApplicationSet |
| `gitops/apps/easytrade/` | Git / ArgoCD | Desired state for EasyTrade; chart version pinned here |
| `helm_release.dynatrace_operator` + DynaKube | Terraform | Cluster-infra observability; independent of ArgoCD |
| `kubernetes_ingress_v1.easytrade_ingress` | Terraform | ALB ingress; stays Terraform-owned this milestone |

**Monorepo layout (post-milestone):**
```
EKS-Trade/
├── main.tf                    (sections 1-4.6, minus section 5)
├── .terraform.lock.hcl
├── .gitignore                 (*.tfstate*, .terraform/, *.tfvars)
└── gitops/
    └── apps/
        └── easytrade/
            ├── Application.yaml   (ArgoCD Application CR, chart version pinned)
            └── values.yaml        (EasyTrade Helm values)
```

### Critical Pitfalls (Top 3 per Phase)

**Phase 1 — State Migration:**
1. **Chicken-and-egg bucket bootstrap** — create the S3 bucket via AWS CLI before adding the `backend "s3"` block; never try to create the bucket inside the same root that declares it as backend. Then run `terraform init -migrate-state`.
2. **Committing `terraform.tfstate.backup`** — write `.gitignore` as the very first file before `git add` anything; verify with `git ls-files --others --exclude-standard | grep tfstate` before committing.
3. **Stale local state after migration** — after confirming remote state with `terraform state list`, delete all local `*.tfstate*` files; run `terraform plan` immediately to confirm zero diff.

**Phase 2 — RDS:**
1. **SG rule opening 5432 to CIDR instead of cluster SG** — the `source_security_group_id` must reference `module.eks.node_security_group_id`, never a CIDR block.
2. **Secrets Manager rotation silently breaking AccountService** — explicitly disable automatic rotation on the secret; AccountService caches credentials at startup and will fail ~30 days after deployment with intermittent auth errors if rotation is active.
3. **Missing `deletion_protection = true`** — set both `deletion_protection = true` on the instance and `lifecycle { prevent_destroy = true }` in Terraform; a stray `terraform destroy` on an unprotected instance is unrecoverable without snapshot restore.

**Phase 3 — ArgoCD Cutover:**
1. **`terraform state rm` skipped before ArgoCD takes ownership** — if `helm_release.easytrade` is still in Terraform state when ArgoCD syncs, Terraform will run `helm uninstall` on next apply, deleting all EasyTrade pods. Run `terraform state rm helm_release.easytrade` first; drops tracking without touching running workloads.
2. **Helm release secret causing ArgoCD `OutOfSync`** — delete the `sh.helm.sh/chart` Helm tracking secret from the `easytrade` namespace before ArgoCD first syncs: `kubectl delete secret -n easytrade -l owner=helm,name=easytrade`.
3. **`auto-prune` deleting Terraform-managed ingress** — set `syncPolicy.automated.prune: false` during cutover; the `kubernetes_ingress_v1` is outside the ArgoCD Application scope and will be pruned if `prune: true` is active on first sync.

**Phase 4 — Dynatrace Operator:**
1. **DynaKube CR applied before CRDs are registered** — set `wait = true` and `timeout = 300` on `helm_release.dynatrace_operator`; `kubernetes_manifest.dynakube` must have `depends_on = [helm_release.dynatrace_operator]`; accept a possible first-apply failure requiring a second `terraform apply`.
2. **Tenant URL format mismatch** — `spec.apiUrl` must be `https://<tenant-id>.live.dynatrace.com/api`, not the browser UI URL (`apps.dynatrace.com`); validate with `curl` from inside the cluster before applying DynaKube.
3. **Operator token missing scopes** — use the Dynatrace UI token wizard with the "Kubernetes: Dynatrace Operator" template to pre-select correct scopes; verify with `kubectl describe dynakube -n dynatrace` — all conditions must show `True` within 5 minutes.

---

## Implications for Roadmap

### Recommended Phase Structure (4 Phases, Coarse-Friendly)

Architecture research suggested 5 phases (separating ArgoCD install from EasyTrade cutover). Features research suggested 4. Given the preference for coarse granularity (3-5 phases, 1-3 plans each), merging ArgoCD install and EasyTrade cutover into one phase is correct — they are a single logical ownership transfer, sequenced as two ordered plans inside the phase. RDS is a prerequisite for ArgoCD first sync, so it stays as its own prior phase.

---

### Phase 1: State Backend + Security Hardening

**Rationale:** Every subsequent apply adds resources to state. The OneDrive state corruption and `0.0.0.0/0` API exposure are both High-severity concerns from `CONCERNS.md`. Resolving them first means all later phases operate safely and every new resource is tracked without corruption risk.

**Delivers:**
- Terraform state in S3 (versioned, AES256 encrypted, S3-native locked); local `*.tfstate*` deleted
- EKS API endpoint restricted to explicit CIDR allow-list
- `.gitignore` in place; first git commit of the repo

**Plans inside this phase:**
1. Bootstrap — AWS CLI creates S3 bucket (versioning + encryption + public-access block); optionally creates DynamoDB table if CLI < 1.10
2. Migration — add `backend "s3"` block + `cluster_endpoint_public_access_cidrs` to `main.tf`; run `terraform init -migrate-state`; verify zero diff

**Research flag:** Standard pattern — skip `/gsd-research-phase`.

---

### Phase 2: RDS Postgres Pilot

**Rationale:** RDS credentials must exist as a Kubernetes Secret in the `easytrade` namespace before ArgoCD first syncs EasyTrade. If Phase 2 is skipped or done after Phase 3, AccountService crash-loops on first ArgoCD sync. Doing RDS second keeps blast radius small — one new AWS resource, one new k8s Secret, one apply.

**Delivers:**
- `db.t4g.micro` Single-AZ Postgres 17 instance in private subnets
- SG locked to EKS node SG (port 5432 only)
- RDS credentials in Secrets Manager (rotation disabled for lab)
- `kubernetes_secret.accountservice-db` in `easytrade` namespace, materialized from Secrets Manager at apply time

**Plans inside this phase:**
1. Single Terraform plan — adds `module.rds_accountservice` (`~> 6.10`), SG, Secrets Manager secret, and `kubernetes_secret` to `main.tf`

**Plan-time verification before apply:** `aws rds describe-db-engine-versions --engine postgres --engine-version 17 --region us-east-1` to confirm `db.t4g.micro` availability.

**Research flag:** Standard pattern — skip `/gsd-research-phase`.

---

### Phase 3: ArgoCD GitOps + EasyTrade Cutover

**Rationale:** This is the largest phase and contains the riskiest operator action. ArgoCD must be installed before the Application CR can exist; the EasyTrade cutover must use `terraform state rm` not `terraform destroy`; and `gitops/` must be authored with the exact chart version currently running. Merging "ArgoCD install" and "EasyTrade cutover" into one phase (with two ordered plans) keeps the ownership transfer atomic from the operator's perspective — no intermediate state where ArgoCD is installed but EasyTrade is still Terraform-owned.

**Delivers:**
- ArgoCD running in `argocd` namespace; ApplicationSet controller managing `gitops/apps/*`
- `gitops/apps/easytrade/Application.yaml` and `values.yaml` committed with pinned chart version
- `helm_release.easytrade` removed from Terraform state and from `main.tf`
- EasyTrade owned by ArgoCD; reports Synced + Healthy; ALB continues serving traffic without interruption
- `kubernetes_ingress_v1.easytrade_ingress.depends_on` updated (fixes the existing empty `depends_on` concern from CONCERNS.md)

**Plans inside this phase:**
1. ArgoCD install plan — adds `helm_release.argocd` and `helm_release.argocd_apps`; authors `gitops/apps/easytrade/` with current chart version; adds `kubernetes_manifest.argocd_app_easytrade` (auto-sync disabled initially)
2. Cutover plan — runs `terraform state rm helm_release.easytrade`; deletes Helm release secret from `easytrade` namespace; removes `helm_release.easytrade` block from `main.tf`; enables `syncPolicy.automated` with `prune: false`; validates ArgoCD Synced + Healthy before enabling `prune: true`

**The riskiest operator action of the milestone:** `terraform state rm helm_release.easytrade` — must execute before ArgoCD Application CR is activated. This drops Terraform tracking without calling `helm uninstall`. Skipping it causes `helm uninstall` on the next `terraform apply`, deleting all EasyTrade pods and the namespace.

**Research flag:** Needs `/gsd-research-phase` at plan time — verify current EasyTrade chart version from `helm list -n easytrade`, confirm OCI registry URL is still `oci://europe-docker.pkg.dev/dynatrace-demoability/helm`, and validate ArgoCD adoption behavior with this specific Helm release's tracking secret.

---

### Phase 4: Dynatrace Operator

**Rationale:** Dynatrace Operator is cluster infra, installed via Terraform Helm — this decision is locked per PROJECT.md. It must be Terraform-managed because operator tokens are provisioned out-of-band from the Dynatrace UI (not via GitOps), and the Operator should predate any app workload so OneAgent injects at pod creation time. Installing after Phase 3 means EasyTrade is already stable, giving Dynatrace a healthy baseline to instrument from the start.

**Delivers:**
- `dynatrace-operator` OCI chart `1.9.0` installed in `dynatrace` namespace
- `kubernetes_secret.dynakube_tokens` created from operator tokens (provided via `TF_VAR_*`, never in `.tfvars` or Git)
- `kubernetes_manifest.dynakube` with `cloudNativeFullStack` mode, scoped to `easytrade` namespace
- ActiveGate running with `kubernetes-monitoring` + `routing`
- EasyTrade traces, metrics, and logs visible in Dynatrace tenant end-to-end

**Plans inside this phase:**
1. Token provisioning (manual, out-of-band) — generate `apiToken` + `dataIngestToken` in Dynatrace tenant UI using "Kubernetes: Dynatrace Operator" wizard; verify cluster egress with `curl` to `<tenant>.live.dynatrace.com/api/v1/time`
2. Operator Terraform plan — adds `helm_release.dynatrace_operator`, `kubernetes_secret.dynakube_tokens`, `kubernetes_manifest.dynakube` to `main.tf`; may require two `terraform apply` runs if CRD registration races the DynaKube manifest

**Research flag:** Partial — token scopes are MEDIUM confidence; use the UI wizard. All other patterns are well-documented.

---

### Phase Ordering Rationale

- **State first:** Every subsequent phase writes resources to state. OneDrive corruption risk is High-severity and eliminated here before any new resources are added. CIDR hardening bundles cleanly — both are low-risk, same apply window.
- **RDS before ArgoCD:** `kubernetes_secret.accountservice-db` must exist before ArgoCD's first EasyTrade sync. AccountService crash-loops on missing DB credentials, making the ArgoCD cutover appear broken even when ArgoCD itself is working correctly.
- **ArgoCD + cutover together:** Separating them (Architecture.md's 5-phase suggestion) creates a valueless intermediate state. Two ordered plans inside one phase is cleaner and reduces total phase count.
- **Dynatrace last:** EasyTrade must be healthy and stable under ArgoCD before OneAgent injection. Pod churn from OneAgent init containers happens once, with a clear before/after. Dynatrace baselining against a half-deployed app produces misleading anomaly alerts.

---

### Research Flags Summary

| Phase | Research Needed? | Reason |
|---|---|---|
| Phase 1: State + Security | No — standard pattern | S3 backend migration is well-documented; CLI bootstrap via AWS CLI is idiomatic |
| Phase 2: RDS | No — standard pattern | Module v6.x + SG + Secrets Manager is well-documented; one CLI verification needed before apply |
| Phase 3: ArgoCD + Cutover | Yes — `/gsd-research-phase` | Current chart version must be discovered; OCI registry URL must be confirmed; ArgoCD adoption mechanics with this specific Helm release need validation |
| Phase 4: Dynatrace | Partial — token scopes only | Operator install is well-documented; token scope list has MEDIUM confidence — use wizard, not manual selection |

---

## Reconciled Decisions

### 1. State Locking: `use_lockfile` vs DynamoDB

**Decision:** Use `use_lockfile = true`. DynamoDB is deprecated in Terraform 1.11 and is the wrong direction for new work.

**Condition:** `use_lockfile = true` is stable in Terraform 1.11+ and available as a feature in 1.10. Verify the installed CLI version before Phase 1 plan. If CLI >= 1.10: use `use_lockfile = true`, provision no DynamoDB table. If CLI < 1.10: provision DynamoDB (`dynamodb_table`) as a fallback and plan a CLI upgrade. This is a plan-time verification, not a roadmap blocker. PROJECT.md's reference to "S3/DynamoDB backend" reflects the user's original framing; the research-backed recommendation is `use_lockfile = true` where the CLI version permits.

### 2. ArgoCD Cutover: Zero-Downtime Path is Non-Negotiable

**Decision:** `terraform state rm helm_release.easytrade` is mandatory. This is the single riskiest operator action of the milestone and must appear explicitly in the Phase 3 runbook.

The sequence: (1) delete Helm release secret from `easytrade` namespace, (2) run `terraform state rm helm_release.easytrade`, (3) remove block from `main.tf`, (4) apply ArgoCD Application CR with auto-sync disabled, (5) trigger manual sync, (6) validate Synced + Healthy, (7) enable auto-sync with `prune: false`, (8) enable `prune: true` only after confirming ArgoCD does not intend to delete the Terraform-managed ingress. Removing the block without `state rm` first causes `helm uninstall` and a downtime window with a sync race — confirmed by both Architecture and Pitfalls research.

### 3. RDS Credentials: Secrets Manager + Rotation Disabled

**Decision:** `manage_master_user_password = true` on the RDS module. Materialize a Kubernetes Secret in the `easytrade` namespace from Secrets Manager data source at apply time. Explicitly disable automatic rotation for the lab.

`random_password` puts plaintext credentials in Terraform state (encrypted at rest in S3, but avoidable). `manage_master_user_password = true` keeps credentials out of state entirely. Secrets Manager 30-day rotation is a silent breaker: AccountService caches credentials at startup and will fail after rotation with no pod restart. For a lab with one operator and no compliance mandate, disabled rotation is the correct call. ESO-based rotation is a v2 concern.

### 4. Dynatrace Operator: Terraform Helm, Not ArgoCD

**Decision:** Locked. Dynatrace Operator is installed via Terraform `helm_release` (section 4.6 in `main.tf`). The `gitops/` folder owns only EasyTrade. ArgoCD does not own anything in the `dynatrace` namespace.

Rationale: tokens flow in via `TF_VAR_*` env vars (not GitOps); the Operator must predate app workloads for injection to work at pod creation time; there is no operational benefit to ArgoCD managing cluster-infra-level addons in a single-cluster lab.

### 5. Phase Count: 4 Phases

**Decision:** 4 phases. Architecture.md's 5-phase suggestion is collapsed by merging ArgoCD install and EasyTrade cutover into one phase with two ordered plans. Features.md's 4-phase sequence is adopted.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Provider versions locked and verified; RDS module v6.x constraint verified against GitHub releases; ArgoCD + Dynatrace chart versions verified against Artifact Hub and GitHub releases |
| Features | HIGH | Table stakes for all four capabilities verified against official docs; deferral decisions consistent with PROJECT.md constraints |
| Architecture | HIGH | Cutover mechanics verified against ArgoCD adoption docs; component ownership boundary is unambiguous and consistent across all four research files |
| Pitfalls | HIGH | Most critical pitfalls have well-documented prevention patterns; Dynatrace token scope list is MEDIUM |

**Overall confidence:** HIGH

### Gaps to Address at Plan Time

| Gap | How to Handle |
|---|---|
| Terraform CLI version | Run `terraform version` before Phase 1 plan; determines `use_lockfile` vs DynamoDB fallback |
| Current EasyTrade chart version | Run `helm list -n easytrade` before Phase 3 plan; required to pin `targetRevision` in `Application.yaml` |
| EasyTrade OCI registry URL | Confirm `oci://europe-docker.pkg.dev/dynatrace-demoability/helm/easytrade` is the current source before Phase 3 plan |
| Dynatrace token scopes | Use "Kubernetes: Dynatrace Operator" wizard in DT UI; verify with `kubectl describe dynakube` after apply |
| PostgreSQL 17 on `db.t4g.micro` in `us-east-1` | Run `aws rds describe-db-engine-versions --engine postgres --engine-version 17 --region us-east-1` before Phase 2 plan |
| Dynatrace tenant ID and egress | Run `curl` from a pod in the cluster to `https://<tenant-id>.live.dynatrace.com/api/v1/time` before Phase 4 plan |

---

## Sources

### Primary (HIGH confidence)
- [HashiCorp S3 Backend Docs](https://developer.hashicorp.com/terraform/language/backend/s3) — `use_lockfile`, IAM permissions, KMS config
- [terraform-aws-rds GitHub Releases](https://github.com/terraform-aws-modules/terraform-aws-rds/releases) — v7.0.0 `aws >= 6.27` requirement; v6.10.0 confirmed last v5-compatible release
- [AWS RDS PostgreSQL Release Notes](https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-versions.html) — PostgreSQL 17 GA status on RDS
- [argo-helm GitHub Releases](https://github.com/argoproj/argo-helm/releases) — chart 9.5.2, appVersion ArgoCD v3.3.7
- [ArgoCD ApplicationSet Official Docs](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/) — Git directory generator pattern
- [ArgoCD Sync Options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/) — adoption and prune behavior
- [Dynatrace Operator GitHub Releases](https://github.com/Dynatrace/dynatrace-operator/releases) — v1.9.0 latest stable
- [Dynatrace Full-Stack Observability Docs](https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/full-stack-observability) — DynaKube CR schema, cloudNativeFullStack mode, two-token requirement
- [Artifact Hub — dynatrace-operator](https://artifacthub.io/packages/helm/dynatrace/dynatrace-operator) — OCI registry URL confirmation
- [Artifact Hub — argocd-apps](https://artifacthub.io/packages/helm/argo/argocd-apps) — version 2.0.4

### Secondary (MEDIUM confidence)
- [Terraform S3 Native Locking announcement](https://medium.com/@mdotsalman/no-more-dynamodb-terraform-1-11-introduces-native-s3-lockfile-support-d668020bd88e) — DynamoDB deprecation timeline (consistent with official docs)
- [Dynatrace EKS DTO Deployment Docs](https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/marketplaces/eks-dto) — token scope list (required cross-referencing with community posts)
- [ArgoCD resource tracking / tracking method conflict](https://github.com/argoproj/argo-cd/issues/18411) — Helm vs ArgoCD label conflict behavior
- [ArgoCD Application adoption (Aviator blog)](https://www.aviator.co/blog/how-to-onboard-an-existing-helm-application-in-argocd/) — adoption-in-place zero-downtime approach

---

*Research completed: 2026-04-20*
*Ready for roadmap: yes*
