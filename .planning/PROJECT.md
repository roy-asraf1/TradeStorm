# EKS-Trade

## What This Is

A single-root Terraform project that stands up a Dynatrace **EasyTrade** demo application on an AWS EKS lab cluster (`easytrade-lab`, k8s 1.34) inside an existing `np-lab` VPC. This milestone hardens the lab toward a more production-like posture — safe state, externalized DB, GitOps-owned app deployment, and first-class observability — while keeping cost characteristics of a lab environment.

## Core Value

**EasyTrade stays reachable via the ALB and fully observable in Dynatrace, with deployments safely reproducible from Git.** If everything else fails, that end-to-end path — `git push → ArgoCD sync → running app → ALB 200 → telemetry in Dynatrace tenant` — must work.

## Requirements

### Validated

<!-- Inferred from existing codebase (.planning/codebase/*). These are already shipped and working. -->

- ✓ EKS control plane + managed node group (SPOT `t3.xlarge`, min=1/desired=1/max=2) in `us-east-1` — existing
- ✓ AWS Load Balancer Controller installed via `eks-blueprints-addons` — existing
- ✓ EasyTrade Helm release deployed into namespace `easytrade` — existing
- ✓ Internet-facing ALB ingress routing to `easytrade-frontendreverseproxy` — existing
- ✓ IRSA (OIDC provider) enabled on the cluster — existing
- ✓ `kube-proxy` addon pinned to latest compatible version via `data.aws_eks_addon_version` — existing

### Active

**Hardening milestone (this cycle):**

- [ ] Migrate Terraform state from local (OneDrive) to S3 backend with DynamoDB state locking
- [ ] Restrict EKS public API endpoint to an explicit CIDR allow-list (remove `0.0.0.0/0` access)
- [ ] Externalize **AccountService** Postgres to a cost-optimized RDS instance (Single-AZ, `db.t4g.micro`) as the RDS pattern; wire EasyTrade to consume it via secrets
- [ ] Install ArgoCD on the cluster via Terraform and bootstrap a monorepo `gitops/` folder as the app source
- [ ] Remove `helm_release.easytrade` from Terraform; EasyTrade is deployed by an ArgoCD `Application` from `gitops/` going forward
- [ ] Install the Dynatrace Operator on the cluster and connect to the existing Dynatrace tenant (operator tokens provisioned during this work)
- [ ] EasyTrade traffic, traces, metrics, and logs visible in the Dynatrace tenant end-to-end

### Out of Scope

- **Multi-AZ / production-grade HA for RDS** — lab posture; `db.t4g.micro` Single-AZ is the explicit cost choice
- **Migrating MSSQL-backed EasyTrade services to RDS** — pilot is Postgres (AccountService) only; evaluate other services in a later milestone
- **Full productization (multi-env overlays, workspaces, CI/CD)** — deferred; the monorepo `gitops/` folder is the only GitOps surface for this milestone
- **Replacing the existing `np-lab` VPC / networking** — stack continues to adopt the existing VPC by id
- **Karpenter, cert-manager, external-dns, kube-prometheus-stack, etc.** — all blueprints add-ons stay disabled; observability goes through Dynatrace Operator, not Prometheus
- **Moving to Pod Identity from IRSA** — noted in codebase concerns; acceptable as-is, not in scope here
- **Private-only EKS endpoint (VPN/bastion)** — CIDR allow-list is the chosen hardening; full private endpoint deferred
- **Load generator (`loadgen.enabled`)** — stays off; external traffic drives the demo

## Context

**Starting state (from `.planning/codebase/`):**

- Single `main.tf` (208 lines) organized as a 7-section narrative: providers → network lookup → cluster → addons → app → ingress → outputs
- Direct providers pinned via `.terraform.lock.hcl`: `aws ~> 5.0` (5.100.0), `kubernetes ~> 2.0` (2.38.0), `helm ~> 2.0` (2.17.0)
- Direct modules: `terraform-aws-modules/eks/aws ~> 20.0` (20.37.2), `aws-ia/eks-blueprints-addons/aws ~> 1.0` (1.23.0)
- Kubernetes/Helm providers authenticate via `data.aws_eks_cluster*` chained off `module.eks`
- `helm_release.easytrade` has no pinned chart version and `wait = false` — relevant to the ArgoCD cutover (chart version must be pinned in the `gitops/` manifest)
- Ingress `depends_on` is effectively empty; first-apply race exists today — GitOps cutover is the moment to fix this contract
- No git-committed `.gitignore` historically; `.planning/` adds one during this workflow
- Hebrew inline comments in `main.tf` — keep convention when editing
- No tests, no CI, no Makefile — this milestone does not add them

**High-severity concerns being addressed this milestone:**

- State lives in OneDrive — risk of sync-corrupted state + bearer tokens synced to Microsoft cloud → resolved by S3/DynamoDB backend
- EKS API public to `0.0.0.0/0` — resolved by CIDR allow-list in the state-backend phase

**High-severity concern deferred:**

- OneDrive read-only directory permissions — shares a fix with the state issue; relocating the project out of `~/Library/CloudStorage/OneDrive-*` is a user action, not a Terraform change

## Constraints

- **Tech stack**: Terraform 1.x + HCL; AWS provider `~> 5.0`; `terraform-aws-modules/eks/aws ~> 20.0`; Kubernetes `1.34`. No new provider families introduced this milestone.
- **Cost**: Lab budget — RDS is Single-AZ `db.t4g.micro`; node group remains SPOT `t3.xlarge`. No multi-AZ, no on-demand fleet, no paid observability add-ons beyond Dynatrace.
- **Networking**: Stack continues to adopt the existing VPC `vpc-01ef4e3d50795d273` and subnets tagged `Name=np-lab-Private-*`. RDS lives in the same private subnets.
- **Region**: `us-east-1` — hardcoded today; extracting to a variable is acceptable but not required this milestone.
- **Cluster access**: EKS public endpoint stays on, but gated by a CIDR allow-list (office/VPN). Private-only endpoint is deferred.
- **GitOps source**: Monorepo — `gitops/` folder inside this same repo. No separate ArgoCD config repo.
- **Observability vendor**: Dynatrace only. Operator connects to an existing tenant; tokens are generated during the Dynatrace phase.
- **Secrets**: RDS credentials and Dynatrace tokens must not land in state or in Git plaintext. Mechanism to be chosen during the relevant phases (AWS Secrets Manager / SSM Parameter Store / sealed secrets / `sops`).

## Key Decisions

| Decision | Rationale | Outcome |
|---|---|---|
| State backend migrates **first**, before RDS / ArgoCD / Dynatrace | State corruption risk in OneDrive is [High]; every subsequent change needs safe tracking | — Pending |
| Bundle EKS API CIDR allow-list fix into the state-backend phase | Both touch cluster/backend config; small incremental change; closes the other [High] concern in the same apply window | — Pending |
| RDS pilot is **AccountService** only (Postgres) | Pilot one DB to prove the pattern with smallest blast radius; AccountService has clean ownership semantics | — Pending |
| RDS sizing: `db.t4g.micro`, Single-AZ | Explicit lab cost choice; no HA requirement for a demo environment | — Pending |
| ArgoCD **owns EasyTrade** after cutover; Terraform loses `helm_release.easytrade` | Clean separation of concerns: Terraform = infra, ArgoCD = apps. Future app changes don't require a Terraform apply. | — Pending |
| GitOps source = this repo's `gitops/` folder (monorepo) | One repo to reason about for a lab; avoids the bootstrap overhead of a second repo | — Pending |
| Observability = Dynatrace Operator only | Demo app is a Dynatrace product; tenant already exists; avoids stacking an unused Prometheus | — Pending |
| Dynatrace Operator installed via Terraform (not ArgoCD) | Operator is cluster-level infra, predates any app sync; matches how cluster add-ons are handled | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-20 after initialization*
