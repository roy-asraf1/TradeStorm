# Feature Research

**Domain:** AWS EKS lab hardening — S3/DynamoDB Terraform backend, RDS Postgres pilot, ArgoCD GitOps, Dynatrace Operator observability
**Researched:** 2026-04-20
**Confidence:** HIGH (official docs + multiple verified sources for all four areas)

---

## Scope Note

This document covers only the four capabilities being **added** this milestone. The existing EKS cluster, ALB ingress, and Helm-deployed EasyTrade are validated baseline requirements — not re-researched here. Lab posture means: cheapest config that proves the pattern, no HA, no multi-env orchestration.

---

## Capability 1: Terraform State — S3 Backend + State Locking

### Table Stakes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| S3 bucket with versioning enabled | Without versioning, a botched apply destroys the only copy of state; recovery requires manual `terraform import` on every resource | LOW | `versioning { enabled = true }` on the bucket resource |
| Encryption at rest | State file embeds bearer tokens, cluster CA certs, IAM ARNs — plaintext S3 is a credential leak | LOW | `server_side_encryption_configuration` with `AES256` (SSE-S3) is sufficient for a lab; no extra cost |
| State locking (S3-native) | Prevents concurrent applies corrupting state | LOW | Terraform 1.10 introduced `use_lockfile = true` on the S3 backend; DynamoDB-based locking is deprecated in Terraform 1.11 and will be removed in a future release. Use `use_lockfile = true` — skip provisioning a DynamoDB table entirely |
| S3 bucket policy blocking public access | Public state = instant credential leak | LOW | `aws_s3_bucket_public_access_block` with all four block flags true |
| Backend key scoped to this project | Prevents overwrite collision if the bucket is shared | LOW | `key = "easytrade-lab/terraform.tfstate"` |
| `terraform init -migrate-state` executed once | Migrates the existing OneDrive local state to S3 | LOW | One-time operator action after backend block is added; old `.tfstate` files on OneDrive can be deleted after |

### Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| KMS CMK instead of SSE-S3 | Audit trail of every decryption via CloudTrail + KMS; fine-grained key policy | MEDIUM | Requires `aws_kms_key` resource + `kms_master_key_id` on the bucket. Overkill for a single-account lab; SSE-S3 is the correct posture here |
| CloudTrail data event on the state bucket | Logs every GetObject/PutObject — state access audit | MEDIUM | Add a CloudTrail trail with `data_resource { type = "AWS::S3::Object" }` scoped to the bucket. Useful if multiple engineers share the bucket |
| S3 cross-region replication | State survives a regional outage | HIGH | Adds a replication role, a destination bucket, and IAM. Entirely unnecessary for a lab; the cluster is also in `us-east-1` — if the region is gone, recovery is a `terraform apply`, not a state restore |

### Anti-Features

| Feature | Why Requested | Why Wrong for a Lab | Instead |
|---------|---------------|---------------------|---------|
| DynamoDB locking table | It was the historic AWS state-locking pattern pre-Terraform 1.10 | Deprecated; adds an extra resource, IAM policy, and billing dimension for no added benefit over `use_lockfile = true` | Use `use_lockfile = true` in the backend block; skip the DynamoDB table entirely |
| Terragrunt wrappers | DRY remote state references across many modules | No multiple modules here; adds a second CLI tool, a `terragrunt.hcl` format, and "which version of Terragrunt am I on?" problems | Native Terraform backend block is sufficient |
| Workspace-per-environment orchestration | Isolate `dev`/`staging`/`prod` state | A lab has one environment; workspaces split state but share a backend config, leading to subtle drift if `terraform.workspace` is not threaded through every resource | Hardcode environment in the bucket key; a second environment gets a second key path if ever needed |
| Multi-account state separation (separate AWS account for state) | True isolation between accounts | Requires cross-account IAM, an assume-role chain in the backend config, and a separate AWS account to manage | Same account, dedicated bucket, scoped bucket policy — adequate for a lab |

---

## Capability 2: RDS Postgres Pilot (AccountService)

### Table Stakes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Private subnet placement + DB subnet group | RDS instance must not be reachable from the internet | LOW | `aws_db_subnet_group` using the same `np-lab-Private-*` subnets the cluster nodes use |
| Security group locked to cluster node SG (or pod SG) | Only EKS workloads can reach port 5432; not the whole VPC | LOW | Ingress rule: `from_port=5432, to_port=5432, protocol=tcp, source_security_group_id = module.eks.node_security_group_id`; tighten to a pod-level SG if SecurityGroupPolicy is used |
| Encrypted storage | Data at rest protected; required by most compliance frameworks even in a lab | LOW | `storage_encrypted = true` — uses the default RDS KMS key; no CMK needed for a lab |
| Automated backups (7-day retention) | Allows point-in-time recovery if a schema migration breaks AccountService | LOW | `backup_retention_period = 7`; `backup_window = "03:00-04:00"` |
| DB parameter group (engine-specific) | Controls Postgres server configuration; default PG parameter group disables `logical_replication`, which is correct for a pilot with no CDC pipeline | LOW | `aws_db_parameter_group` for `postgres16`; no parameter overrides needed; just associates the correct family |
| Credentials stored in AWS Secrets Manager | Passwords must not appear in Terraform state, Git, or pod env vars in plaintext | MEDIUM | `aws_secretsmanager_secret` + `aws_secretsmanager_secret_version`; EasyTrade AccountService reads from the secret ARN via an environment variable or a projected volume |
| `publicly_accessible = false` | Belt-and-suspenders with subnet placement | LOW | Explicit flag on `aws_db_instance` |
| `deletion_protection = false` for lab | Allows `terraform destroy` to complete; flip to `true` in any non-lab environment | LOW | Lab teardown would block otherwise |

### Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| IAM database authentication | Eliminates long-lived password; pod assumes an IAM role via IRSA, calls `rds-db:connect`, exchanges token for a 15-minute credential | HIGH | Requires: `iam_database_authentication_enabled = true`, an IRSA role on the pod SA, a Postgres user created with `GRANT rds_iam`, and the app updated to generate the token. Proves the pattern cleanly in a v2 milestone |
| Performance Insights | Query-level performance visibility in the RDS console | LOW | `performance_insights_enabled = true`; free tier covers 7 days of retention. Safe to enable even in a lab — no cost at `db.t4g.micro` |
| Enhanced monitoring (60s granularity) | OS-level metrics (CPU steal, I/O wait) via CloudWatch | LOW | `monitoring_interval = 60`, `monitoring_role_arn = aws_iam_role.rds_monitoring.arn`; requires an IAM role with `AmazonRDSEnhancedMonitoringRole` |

### Anti-Features

| Feature | Why Requested | Why Wrong for a Lab | Instead |
|---------|---------------|---------------------|---------|
| Multi-AZ (`multi_az = true`) | Production HA; standby in a second AZ with automatic failover | Doubles the instance cost; the lab explicitly uses `db.t4g.micro` Single-AZ as its cost choice; PROJECT.md marks this out of scope | `multi_az = false` — hardcode, document why |
| Read replica | Offload read traffic from primary | No read-heavy workload in a lab; AccountService is a CRUD API, not an analytics query | Not needed; one instance is the pilot |
| RDS Proxy | Connection pooling for short-lived pod connections | Proxy has a minimum cost (~$0.015/hour), requires Secrets Manager integration on its own config, and adds a debugging layer between the app and the DB | Direct connection from pod to RDS; EasyTrade's connection pool is small |
| Automated snapshots exported to S3 | Cross-service backup for compliance | Manual snapshot export requires a separate IAM role and S3 bucket; the 7-day automated backup window already covers recovery for a lab | `backup_retention_period = 7` is sufficient |
| Migrating MSSQL-backed EasyTrade services | Consolidate all DBs onto RDS | Out of scope per PROJECT.md; AccountService is the only Postgres pilot | Complete the pilot, evaluate in a later milestone |

---

## Capability 3: ArgoCD GitOps — EasyTrade Cutover

### Table Stakes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| ArgoCD server installed into `argocd` namespace | Without the server, there is no GitOps control plane | LOW | Deployed via Helm (`oci://ghcr.io/argoproj/argo-helm/argo-cd`); the `aws-ia/eks-blueprints-addons` module already has an ArgoCD sub-addon available |
| A single ArgoCD `Application` CR pointing at `gitops/` | This is the GitOps contract: a CR in the cluster drives the desired state from the repo | LOW | `Application` with `source.repoURL = <this repo>`, `source.path = gitops/`, `source.targetRevision = HEAD`, `destination.server = https://kubernetes.default.svc` |
| EasyTrade Helm manifest in `gitops/` with pinned chart version | ArgoCD needs a declarative source; unpinned chart version would cause silent drift — the same bug that exists in the current `helm_release.easytrade` | LOW | `gitops/easytrade/Chart.yaml` or a raw `HelmRelease` / `Application` with `helm.chart`, `helm.version` pinned |
| `helm_release.easytrade` removed from Terraform | After ArgoCD takes ownership, Terraform managing the same Helm release creates a split-brain | MEDIUM | Requires a `terraform state rm helm_release.easytrade` before or during the cutover apply; if both manage it simultaneously, the next ArgoCD sync will conflict |
| RBAC: at least one admin account | ArgoCD with only the initial `admin` password is functional but fragile; admin password should be changed | LOW | Set `argocd-cm` admin password hash via Helm values or `kubectl patch secret argocd-initial-admin-secret`; at minimum, document the initial password retrieval procedure |
| Ingress or port-forward for UI access | Without UI or CLI access, operators cannot inspect sync status | LOW | For a lab: `kubectl port-forward svc/argocd-server -n argocd 8080:443` is sufficient; OR add an ALB ingress using the existing ALB controller; either approach works |
| Self-heal explicitly configured (default: disabled) | Self-heal auto-reverts manual `kubectl` changes; for a lab where you frequently `kubectl apply` to debug, keeping it off prevents frustrating rollbacks | LOW | `syncPolicy.automated.selfHeal = false` is the ArgoCD default; explicitly document this in the Application CR |
| `syncPolicy.automated.prune = false` for initial cutover | Prevents ArgoCD from deleting resources created by Terraform during the overlap window | LOW | Flip to `true` once Terraform has cleanly removed `helm_release.easytrade` |

### Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Git webhook for fast sync | Default poll interval is 3 minutes; a webhook triggers sync on push, reducing feedback loop to seconds | MEDIUM | Requires a webhook secret in the repo settings pointing at the ArgoCD server's `/api/webhook` endpoint; the server must be externally reachable (ALB or port-forward won't work for webhooks from GitHub) |
| ApplicationSets | Generate multiple Application CRs from a template + generator (e.g., directory generator per service) | MEDIUM | Useful if `gitops/` grows to many services; overkill for a single EasyTrade app in a lab |
| Sync waves (`argocd.argoproj.io/sync-wave`) | Order resource creation within a sync — e.g., CRDs before Deployments, Secrets before Deployments | LOW | Even a simple wave annotation (`sync-wave: "-1"` on Secrets) prevents intermittent sync failures when resources have ordering dependencies |
| Notifications (Slack/email on sync fail) | Alerts when GitOps breaks silently | MEDIUM | Requires `argocd-notifications` controller + a notifier config + credentials for the channel; valuable in a shared lab where multiple people push |
| OIDC SSO (not Dex) | Single sign-on via an external OIDC provider (Google, Okta, GitHub) | HIGH | Skips Dex; configures `oidc.config` in `argocd-cm` directly; only useful if multiple human users need separate identities in a lab |

### Anti-Features

| Feature | Why Requested | Why Wrong for a Lab | Instead |
|---------|---------------|---------------------|---------|
| Dex SSO | Built-in identity broker bundled with ArgoCD; often cited as the "standard" SSO approach | Dex adds a separate deployment, a secret for client credentials, and a multi-step OIDC flow just to log into a UI one person uses; in a lab, `admin` with a strong password is sufficient | Use the `admin` account; disable Dex by setting `server.dex.server.disable = true` in Helm values |
| Multi-cluster ArgoCD (hub-and-spoke) | Manage many EKS clusters from one ArgoCD instance | This is a single-cluster lab; multi-cluster setup requires cluster secrets and additional RBAC; the benefit is zero here | `destination.server = https://kubernetes.default.svc` — ArgoCD manages its own cluster only |
| Argo Image Updater | Automatically bumps image tags in Git when a new container image is pushed | Introduces a second write-back loop to Git; image tags change nondeterministically; requires a bot token with push access; the lab's app lifecycle is driven by explicit Git pushes | Pin the EasyTrade chart version and bump it manually when needed |
| Argo Rollouts | Progressive delivery (canary, blue/green) | Adds a new CRD, a controller, and replaces standard Kubernetes `Deployment` semantics; EasyTrade is a demo app where "does it come up" is the acceptance criterion | Standard Kubernetes Deployment rollout strategy is sufficient |
| ArgoCD Projects with scoped repositories and clusters | Multi-team RBAC isolation | A lab has one team and one cluster; `default` project is correct | Use the `default` project; document project scoping as a v2 concern |
| HA ArgoCD install | Redundant application-controller, repo-server, and Redis HA | Requires 3+ nodes; the cluster runs `min=1` SPOT; HA install would not actually achieve HA on a single SPOT node | Non-HA install (`argocd-install.yaml` not `argocd-ha-install.yaml`) |

---

## Capability 4: Dynatrace Operator — EKS Observability

### Table Stakes

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Dynatrace Operator installed via Helm | The operator manages the lifecycle of all Dynatrace components on the cluster; without it there is nothing to configure | LOW | `helm install dynatrace-operator oci://public.ecr.aws/dynatrace/dynatrace-operator` or the official Helm repo; Terraform `helm_release` block in the cluster add-ons section |
| `DynaKube` CR created with correct API URL and token secret reference | The CR is the reconciliation target; without it the operator installs but does nothing | LOW | `apiUrl: https://<tenant-id>.live.dynatrace.com/api`; `tokenRef.name: dynakube-tokens` |
| OneAgent on every node (DaemonSet via CSI driver) | Without OneAgent on the node, process-level metrics, host metrics, and code-level instrumentation are unavailable | LOW | `oneAgent.hostMonitoring: {}` in the DynaKube spec deploys a DaemonSet; the operator uses its own CSI driver to mount the agent binary — no cert-manager dependency |
| Automatic code injection into `easytrade` namespace | Pods in the `easytrade` namespace get OneAgent code module injected via the Dynatrace webhook admission controller | LOW | Annotate the namespace: `instrumentationEnabled: "true"` OR set `namespaceSelector` in the DynaKube CR to target `easytrade`; the webhook is deployed by the operator automatically |
| ActiveGate deployed (for Kubernetes API monitoring) | ActiveGate is the metrics routing component; also required for Kubernetes-level metrics (node, pod, container) to appear in the Dynatrace tenant | LOW | `activeGate.capabilities: [kubernetes-monitoring, routing]` in the DynaKube spec; runs as a Deployment with a ClusterRole |
| Tokens stored in a Kubernetes Secret (not in Git or state) | `dataIngestToken` and `apiToken` must not appear in Terraform state or GitOps manifests plaintext | MEDIUM | Create `aws_secretsmanager_secret` for the tokens; use an External Secrets Operator or a Terraform-provisioned `kubernetes_secret` populated from SSM/Secrets Manager at apply time; the secret name is referenced in the DynaKube CR |
| `easytrade` traffic + traces visible in tenant end-to-end | The milestone acceptance criterion; if this is not green, the install is incomplete | MEDIUM | Requires OneAgent injection + ActiveGate routing + a running EasyTrade app generating traffic |

### Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Kubernetes API monitoring enabled | Node, pod, namespace, workload-level metrics flow into Dynatrace's Kubernetes dashboard (not just host/process) | LOW | `activeGate.capabilities` must include `kubernetes-monitoring`; grant the ActiveGate's ServiceAccount a `ClusterRole` with `get`/`list`/`watch` on core and apps resources |
| Prometheus scrape via Dynatrace (`prometheusExporter`) | If any service in `easytrade` exposes a `/metrics` endpoint, Dynatrace can ingest those without a separate Prometheus stack | MEDIUM | Set `metricIngestEndpoint` annotation on the pod or configure the `prometheusExporter` in the DynaKube CR; keeps the no-Prometheus-stack commitment from PROJECT.md |
| Log monitoring (log ingest from pods) | Pod stdout/stderr captured and correlated with traces | LOW | `logMonitoring: enabled: true` in the DynaKube CR; requires OneAgent DaemonSet (already a table stake) |
| Real User Monitoring (RUM) injection into frontend | Browser-level user sessions, waterfall timings, JS errors appear in Dynatrace | MEDIUM | Inject the Dynatrace JavaScript tag into the EasyTrade frontend HTML; can be done via the OneAgent automatic injection for certain frameworks, or manually adding the RUM snippet to the frontend Helm chart values |

### Anti-Features

| Feature | Why Requested | Why Wrong for a Lab | Instead |
|---------|---------------|---------------------|---------|
| Dynatrace Synthetic monitors | Simulate user journeys from Dynatrace locations on a scheduled basis | Requires configuring external Dynatrace synthetic locations, setting up monitors in the tenant UI, and costs DPU credits on the tenant; the ALB is already serving real (or demo) traffic | Use real traffic through the ALB; no synthetics needed |
| Session Replay | Records actual browser session interactions | Session Replay requires a separate license entitlement on the tenant, extra JavaScript overhead, and user consent configuration — disproportionate for a lab | RUM (the differentiator above) is sufficient for a demo |
| Grail ingestion tuning (retention, DDUs, bucket configuration) | Right-size Dynatrace consumption billing | Grail is a tenant-level concern, not a cluster concern; the operator does not manage this; tuning it requires Dynatrace admin access and knowledge of the tenant's license model | Accept tenant defaults; revisit only if the lab runs long enough to accumulate significant DDU spend |
| Cost governance dashboards (Davis AI tuning) | Understand and cap Dynatrace consumption | Requires Dynatrace admin rights and a custom dashboard; complex to set up correctly; lab duration is short | Not needed; review tenant usage manually if cost is a concern |
| Multi-instance DynaKube (separate DynaKube per namespace) | Fine-grained injection control per team | One DynaKube with a `namespaceSelector` targeting `easytrade` is sufficient; multiple DynaKubes add operator reconciliation complexity | Single DynaKube CR with namespace selector |

---

## Feature Dependencies

```
[S3 Backend Migration]
    └──must-complete-before──> [RDS Pilot]
    └──must-complete-before──> [ArgoCD Install]
    └──must-complete-before──> [Dynatrace Operator]
        (all subsequent apply cycles need safe, non-corrupted state)

[EKS Cluster + IRSA]
    └──required-by──> [RDS Pilot] (IRSA needed if IAM DB auth differentiator is chosen)
    └──required-by──> [ArgoCD Install] (Helm provider authenticates via cluster)
    └──required-by──> [Dynatrace Operator] (Helm + kubernetes provider)

[ArgoCD Install]
    └──must-precede──> [EasyTrade cutover from helm_release to Application CR]
    └──terraform-state-rm──> [helm_release.easytrade removal]
        (split-brain risk if both manage the Helm release simultaneously)

[Dynatrace Operator Install]
    └──required-by──> [OneAgent DaemonSet] (operator deploys it)
    └──required-by──> [Webhook injection into easytrade namespace]
    └──required-by──> [ActiveGate routing]
        (all Dynatrace components are children of the operator + DynaKube CR)

[EasyTrade running in easytrade namespace]
    └──required-by──> [Dynatrace end-to-end validation]
    └──required-by──> [ArgoCD sync status green]

[Dynatrace Operator]
    ──does-NOT-require──> [cert-manager]
        (operator uses its own CSI driver; cert-manager is not a dependency
         for OneAgent DaemonSet or webhook injection as of Operator 1.x)

[RDS Postgres instance]
    └──required-by──> [AccountService DB wiring in gitops/ Helm values]
    └──secret ARN must be available──> [before ArgoCD first syncs easytrade]
        (if AccountService crashes on missing DB, the app is broken at first sync)
```

### Dependency Notes

- **S3 backend before everything else:** The existing state in OneDrive is corrupted-risk on every apply. All four subsequent capabilities add significant resources to state — migrating first ensures every change is tracked safely.
- **ArgoCD cutover requires a `terraform state rm` step:** The `helm_release.easytrade` resource must be removed from Terraform state before ArgoCD creates the same Helm release from `gitops/`, or the two controllers fight over the same release. This is an operator action, not a Terraform resource change.
- **RDS before ArgoCD first sync of EasyTrade:** If AccountService is wired to RDS and the RDS instance (or secret) does not exist when ArgoCD first syncs, AccountService pods will crash-loop. Provision RDS, confirm the secret ARN, inject it into `gitops/` Helm values, then enable the ArgoCD Application.
- **Dynatrace Operator does not require cert-manager:** As of Dynatrace Operator 1.x, the operator deploys its own webhook certificates using the CSI driver infrastructure. cert-manager is explicitly disabled in PROJECT.md (`eks_blueprints_addons` add-ons stay off). No change needed.
- **ActiveGate needs a ClusterRole:** The Kubernetes API monitoring capability requires the ActiveGate ServiceAccount to have read access to cluster resources. The operator creates this automatically when `kubernetes-monitoring` is listed in capabilities — no manual RBAC needed.

---

## MVP Definition

### This Milestone (v1 — Hardening)

The milestone is complete when the following are true:

- [ ] S3 backend active, `use_lockfile = true`, versioning and encryption on the bucket, `terraform.tfstate` no longer in OneDrive — resolves both High-severity concerns from CONCERNS.md
- [ ] EKS public endpoint restricted to explicit CIDR allow-list
- [ ] RDS `db.t4g.micro` Postgres instance in private subnets, SG locked to cluster SG, encrypted, 7-day backup, credentials in Secrets Manager
- [ ] ArgoCD installed, `Application` CR pointing at `gitops/`, `helm_release.easytrade` removed from Terraform state and from `main.tf`
- [ ] EasyTrade chart version pinned in `gitops/`, ArgoCD reports Synced + Healthy, ALB continues to serve traffic
- [ ] Dynatrace Operator installed, DynaKube CR applied, OneAgent DaemonSet running on node, injection active in `easytrade` namespace, ActiveGate routing metrics, tenant shows EasyTrade traffic/traces

### Defer to v2

- [ ] IAM database authentication for RDS (eliminate long-lived password) — trigger: second engineer joining the lab
- [ ] Git webhook for ArgoCD fast sync — trigger: push-to-deploy feedback loop becomes annoying
- [ ] Performance Insights + Enhanced Monitoring on RDS — trigger: query performance debugging needed
- [ ] RUM injection into EasyTrade frontend — trigger: user-experience demo required
- [ ] Prometheus scrape via Dynatrace — trigger: a service in easytrade exposes /metrics
- [ ] ApplicationSets — trigger: gitops/ grows to more than 3 independent apps

### Out of Scope (do not build)

- Multi-AZ RDS, read replica, RDS Proxy — explicit cost/complexity rejection per PROJECT.md
- Dex SSO, Argo Rollouts, Argo Image Updater — over-engineering for a single-user lab
- Dynatrace Synthetic monitors, Session Replay, Grail tuning — disproportionate for lab duration
- Terragrunt, workspaces, multi-account state — no multi-environment requirement

---

## Feature Prioritization Matrix

| Feature | Lab Value | Implementation Cost | Priority |
|---------|-----------|---------------------|----------|
| S3 backend + versioning + native locking | HIGH (blocks everything) | LOW | P1 |
| EKS CIDR allow-list | HIGH (security) | LOW | P1 |
| RDS private placement + SG + encryption | HIGH (pattern proof) | LOW | P1 |
| Credentials in Secrets Manager | HIGH (security) | MEDIUM | P1 |
| ArgoCD server install | HIGH (GitOps control plane) | LOW | P1 |
| EasyTrade Application CR + gitops/ | HIGH (cutover goal) | MEDIUM | P1 |
| helm_release.easytrade removal + state rm | HIGH (avoid split-brain) | MEDIUM | P1 |
| Dynatrace Operator + DynaKube CR | HIGH (observability goal) | LOW | P1 |
| OneAgent DaemonSet + namespace injection | HIGH (end-to-end telemetry) | LOW | P1 |
| ActiveGate for Kubernetes API monitoring | HIGH (K8s metrics) | LOW | P1 |
| Automated backups (7-day) | MEDIUM (recovery) | LOW | P2 |
| Performance Insights on RDS | MEDIUM (debugging) | LOW | P2 |
| Sync waves in ArgoCD Application | MEDIUM (ordering) | LOW | P2 |
| Log monitoring via Dynatrace | MEDIUM (correlation) | LOW | P2 |
| Git webhook for ArgoCD | LOW (convenience) | MEDIUM | P3 |
| IAM DB auth for RDS | LOW (lab has one engineer) | HIGH | P3 |
| RUM injection into frontend | LOW (demo polish) | MEDIUM | P3 |
| ApplicationSets | LOW (one app) | MEDIUM | P3 |

---

## Sources

- Terraform S3 backend official docs: https://developer.hashicorp.com/terraform/language/backend/s3
- Terraform 1.10/1.11 S3 native locking (DynamoDB deprecation): https://rafaelmedeiros94.medium.com/goodbye-dynamodb-terraform-s3-backend-now-supports-native-locking-06f74037ad37
- AWS prescriptive guidance on Terraform backend: https://docs.aws.amazon.com/prescriptive-guidance/latest/terraform-aws-provider-best-practices/backend.html
- ArgoCD on EKS — AWS docs: https://docs.aws.amazon.com/eks/latest/userguide/argocd.html
- EKS Workshop ArgoCD app-of-apps: https://www.eksworkshop.com/docs/automation/gitops/argocd/app-of-apps/setup
- Dynatrace Operator docs: https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/how-it-works/components/dynatrace-operator
- Dynatrace DynaKube parameters: https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/reference/dynakube-parameters
- Dynatrace full-stack observability on Kubernetes: https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/full-stack-observability
- RDS + EKS security group per pod pattern: https://www.eksworkshop.com/docs/networking/vpc-cni/security-groups-for-pods/add-sg
- RDS Secrets Manager integration: https://asecure.cloud/a/RDS_PostgrSQL/

---
*Feature research for: AWS EKS lab hardening (EasyTrade)*
*Researched: 2026-04-20*
