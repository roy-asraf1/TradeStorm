# Pitfalls Research

**Domain:** AWS EKS lab hardening — S3/DynamoDB backend, RDS pilot, ArgoCD GitOps cutover, Dynatrace Operator observability
**Researched:** 2026-04-20
**Confidence:** HIGH (per-pitfall confidence noted inline)

> **Scope note:** Pitfalls already acknowledged in `.planning/codebase/CONCERNS.md` (state-in-OneDrive, 0.0.0.0/0 API endpoint, unpinned `helm_release.easytrade`, `wait=false` + empty `depends_on`, `alb_dns_name` unsafe index) are **not repeated here**. This file covers new failure modes introduced by the four hardening capabilities.

---

## Phase 1 — State Migration (S3 / DynamoDB)

### [Critical] Chicken-and-egg: bootstrapping the bucket/table via Terraform

**What goes wrong:**
You write a `terraform` backend block pointing to an S3 bucket that doesn't exist yet, then run `terraform init`. Init fails immediately with `BucketNotFound`. If you try to create the bucket *with Terraform* in the same root module that declares the backend, you have a paradox: the backend needs the bucket, and the bucket needs a successful apply, which needs the backend.

**Why it happens:**
Developers naturally reach for Terraform to create everything. The S3 backend configuration is validated during `init`, before any resource is created.

**How to avoid:**
Create the bucket and DynamoDB table out-of-band **before** touching `main.tf`:

```bash
# One-shot bootstrap — run once, then never touch these manually again
aws s3api create-bucket \
  --bucket eks-trade-tfstate-<account-id> \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket eks-trade-tfstate-<account-id> \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket eks-trade-tfstate-<account-id> \
  --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket eks-trade-tfstate-<account-id> \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

Then add the `backend "s3"` block and run `terraform init -migrate-state`.

**Warning signs:**
- `Error: Failed to get existing workspaces: BucketNotFound` — you ran `init` before bucket exists.
- `Error: Failed to instantiate provider` during `plan` — backend init failed silently.

**Phase to address:** State-migration phase, first task.

---

### [Critical] Stale local state after migration — old file stays, someone runs from wrong path

**What goes wrong:**
After `terraform init -migrate-state` succeeds, the local `terraform.tfstate` and `terraform.tfstate.backup` files are **not deleted automatically**. If someone runs `terraform plan` from a directory where the backend block is not yet present (e.g., a detached copy still on OneDrive, or after reverting a git change), Terraform reads the stale local file and produces a plan that reflects an old snapshot of reality. A subsequent `apply` can attempt to re-create resources that already exist, or worse, destroy resources that were added after the last local-file snapshot.

**Why it happens:**
Terraform does not enforce that local state files are removed post-migration. The OneDrive project root has multiple snapshot files (`*.1776080330.backup`, `*.1776080333.backup`) that are already diverged — the migration window is the last moment when these diverge further.

**How to avoid:**

1. After confirming remote state is intact (`terraform state list` against S3), explicitly delete local state artefacts:
   ```bash
   rm terraform.tfstate terraform.tfstate.backup
   rm -f *.backup   # removes the OneDrive snapshot variants
   ```
2. Verify `.gitignore` already excludes `*.tfstate*` before the first `git add` post-migration.
3. Run `terraform plan` immediately after migration and confirm zero diff — this proves the remote state was imported correctly.

**Warning signs:**
- `terraform plan` shows resources to be re-created that are clearly running in AWS.
- `git status` shows `terraform.tfstate` or `*.tfstate.backup` as untracked files after migration.

**Phase to address:** State-migration phase, immediately after `init -migrate-state` succeeds.

---

### [Critical] Accidentally committing `terraform.tfstate.backup` after migration

**What goes wrong:**
The current repo has no committed `.gitignore`. During the migration phase the repo gets its first commit. If `.gitignore` is written after `git add .` (or `git add -A`) is run, any `*.tfstate*` file in the working tree gets committed. The backup file contains embedded EKS cluster CA cert, `aws_eks_cluster_auth` short-lived bearer token ARNs, all IAM role ARNs, and the full VPC/subnet topology — all in plaintext JSON.

**Why it happens:**
First-commit excitement: "add everything, fix up later." The backup file is invisible unless you look for it — it doesn't show up in `terraform plan` output.

**How to avoid:**
Write `.gitignore` as the **first file** in the first commit, before staging anything else:

```gitignore
# State
.terraform/
terraform.tfstate
terraform.tfstate.backup
*.tfstate
*.tfstate.*

# Secrets
*.auto.tfvars
terraform.tfvars
```

Verify before committing:
```bash
git ls-files --others --exclude-standard | grep tfstate   # should return nothing
```

**Warning signs:**
- `git status` shows `terraform.tfstate.backup` as "Changes to be committed."
- `git log --stat` on the first commit includes any `.tfstate` file.

**Phase to address:** State-migration phase, before first git commit.

---

### [High] DynamoDB lock permissions missing — Terraform fails loudly, not silently

**What goes wrong:**
The role running `terraform apply` lacks `dynamodb:PutItem`, `dynamodb:GetItem`, `dynamodb:DeleteItem`, or `dynamodb:DescribeTable` on the lock table. Terraform will throw `AccessDeniedException` on lock acquisition and **refuse to proceed** — this is not silent. However, if the operator sees the error, force-unlocks manually, and never fixes the IAM, future applies run without locking protection.

> **Note (Terraform 1.11+):** Terraform 1.11 introduced S3-native state locking (GA) that eliminates the DynamoDB dependency entirely. The existing constraint `required_version >= 1.5.0` in CONCERNS.md means this project may target < 1.11; check which version is installed before deciding whether to provision DynamoDB at all.

**How to avoid:**
Add to the IAM policy for the Terraform execution role:

```json
{
  "Effect": "Allow",
  "Action": [
    "dynamodb:DescribeTable",
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:DeleteItem"
  ],
  "Resource": "arn:aws:dynamodb:us-east-1:<account>:table/terraform-locks"
}
```

Test with a dry run before declaring the migration complete:
```bash
aws dynamodb put-item --table-name terraform-locks \
  --item '{"LockID":{"S":"test-lock"}}' --region us-east-1
aws dynamodb delete-item --table-name terraform-locks \
  --key '{"LockID":{"S":"test-lock"}}' --region us-east-1
```

**Warning signs:**
- `Error acquiring the state lock: AccessDeniedException` in `terraform apply` output.
- Any `terraform force-unlock` being run — this is a red flag that the lock is not working and humans are working around it.

**Phase to address:** State-migration phase, IAM configuration step.

---

### [High] KMS key policy denying the execution role

**What goes wrong:**
If a CMK is used for S3 server-side encryption (rather than the simpler `AES256` default), the IAM role running Terraform needs `kms:GenerateDataKey`, `kms:Decrypt`, `kms:DescribeKey`, and `kms:ReEncrypt*` granted in the **key policy** (not just the IAM policy). KMS key policies are independent of IAM policies — granting in IAM alone is insufficient. The error is cryptic: `KMS.KmsInvalidStateException` or `Access Denied` on an S3 `PutObject`, not on a KMS call.

**How to avoid:**
For a lab environment, use `AES256` (AWS-managed S3 SSE) instead of a CMK. This eliminates the key policy complexity entirely:

```hcl
backend "s3" {
  bucket         = "eks-trade-tfstate-<account>"
  key            = "easytrade-lab/terraform.tfstate"
  region         = "us-east-1"
  encrypt        = true          # uses AES256 SSE-S3 by default; no kms_key_id needed
  dynamodb_table = "terraform-locks"
}
```

If a CMK is required by policy, add the execution role's ARN explicitly in the key policy `Principal` block — do not rely on the IAM-delegates-to-KMS path alone.

**Warning signs:**
- `Error putting S3 object: AccessDenied` after `encrypt = true` is set with a `kms_key_id`.
- `CloudTrail` shows `GenerateDataKey` calls being denied.

**Phase to address:** State-migration phase, bucket configuration step.

---

### [Medium] OneDrive sync race during the migration window

**What goes wrong:**
Between the moment `terraform init -migrate-state` copies the state to S3 and the moment local files are deleted, OneDrive's sync daemon can upload the old local state file to a second device or create a conflict copy (`terraform.tfstate (conflicted copy).*`). If someone on a second machine pulls the OneDrive sync and runs Terraform without the backend block, they operate against the stale local file.

**How to avoid:**
Perform the migration in a single uninterrupted session:

1. Pause OneDrive sync before starting (`System Preferences → OneDrive → Pause Syncing`).
2. Complete: write backend block → `terraform init -migrate-state` → verify → delete local files → first git commit.
3. Resume OneDrive sync only after the local state files are gone and git tracks the `.gitignore`.

The long-term fix is relocating the project out of `~/Library/CloudStorage/OneDrive-*` — already noted in CONCERNS.md as a prerequisite user action.

**Warning signs:**
- OneDrive menu bar shows "Syncing" during a `terraform apply`.
- A conflict copy file (`*.tfstate (conflicted copy).*`) appears in the directory.

**Phase to address:** State-migration phase, pre-migration checklist.

---

## Phase 2 — RDS (AccountService Postgres Pilot)

### [Critical] delete_protection = false + no prevent_destroy — one terraform destroy wipes the DB

**What goes wrong:**
`aws_db_instance` defaults to `deletion_protection = false`. Without `prevent_destroy` in the Terraform lifecycle, a stray `terraform destroy` or a `-target` applied to the wrong resource permanently deletes the RDS instance and all data. Recovery requires restoring from the automated snapshot, which is a manual, time-consuming operation even in a lab.

**How to avoid:**
Apply both layers of protection:

```hcl
resource "aws_db_instance" "accountservice" {
  # ... other config ...
  deletion_protection = true     # AWS-level: refuses DELETE API call

  lifecycle {
    prevent_destroy = true       # Terraform-level: refuses plan that would destroy this resource
  }
}
```

Note: `prevent_destroy` does not survive when the resource block is removed from HCL — if you remove the resource block entirely, Terraform ignores `prevent_destroy`. For that case, manual `aws rds delete-db-instance --skip-final-snapshot` is required.

**Warning signs:**
- `terraform plan` output shows `- aws_db_instance.accountservice will be destroyed`.
- No `deletion_protection = true` visible in `terraform show` output for the instance.

**Phase to address:** RDS phase, initial resource definition.

---

### [Critical] SG rules opening 5432 to 0.0.0.0/0 instead of just the cluster SG

**What goes wrong:**
The most common shortcut when debugging connectivity is opening the RDS security group to all traffic. Once the app works, this permissive rule stays. The RDS instance is in private subnets, so this doesn't create immediate public access — but it means any workload in the VPC (including compromised pods in other namespaces) can reach the database directly.

**How to avoid:**
The RDS security group's inbound rule must reference the EKS **node group security group ID** (or the EKS cluster-managed security group), not a CIDR:

```hcl
resource "aws_security_group_rule" "rds_from_eks_nodes" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = module.eks.node_security_group_id
}
```

The EKS module exposes `module.eks.node_security_group_id` and `module.eks.cluster_security_group_id` — use one of these, not `0.0.0.0/0` or the VPC CIDR.

**Warning signs:**
- SG rule shows `cidr_blocks = ["0.0.0.0/0"]` or `cidr_blocks = ["10.0.0.0/8"]` for port 5432.
- `aws ec2 describe-security-group-rules` shows an inbound rule with a CIDR source on the RDS SG.

**Phase to address:** RDS phase, security group definition.

---

### [Critical] subnet_group placed in public subnets

**What goes wrong:**
The `aws_db_subnet_group` is given the wrong subnet IDs — the public subnets instead of the private ones. Combined with `publicly_accessible = false`, the RDS instance itself won't have a public IP, but it sits in a subnet with an internet gateway route, which violates the network isolation principle and fails compliance checks. If `publicly_accessible = true` is also accidentally set (see next pitfall), the instance *will* get a public hostname.

**How to avoid:**
This project already uses `data.aws_subnets.private` which filters on `tag:Name = "np-lab-Private-*"`. Reuse that data source for the subnet group:

```hcl
resource "aws_db_subnet_group" "accountservice" {
  name       = "accountservice-subnet-group"
  subnet_ids = data.aws_subnets.private.ids   # ← same as EKS nodes; confirmed private
}
```

**Warning signs:**
- `aws rds describe-db-subnet-groups` shows subnets with a route to an Internet Gateway.
- `terraform plan` shows `subnet_ids` referencing IDs that don't match the `np-lab-Private-*` tag.

**Phase to address:** RDS phase, subnet group definition.

---

### [High] publicly_accessible = true accidentally on

**What goes wrong:**
`publicly_accessible = false` is not the default for `aws_db_instance` — the provider default is `false` only in certain configurations but the safest posture is to **explicitly set it**. Forgetting the attribute or setting it to `true` during debugging (to test connectivity from a local machine) gives the instance a public DNS name and makes it reachable from the internet if the SG is also permissive.

**How to avoid:**
Always explicit:

```hcl
resource "aws_db_instance" "accountservice" {
  publicly_accessible = false   # explicit, not default-relied-on
}
```

**Warning signs:**
- `aws rds describe-db-instances --query 'DBInstances[].PubliclyAccessible'` returns `true`.
- The RDS endpoint hostname resolves to a public IP.

**Phase to address:** RDS phase, initial resource definition.

---

### [High] Credentials rotation breaking the app — EasyTrade caches DB creds at startup

**What goes wrong:**
Secrets Manager default rotation is 30 days. EasyTrade's AccountService (a .NET or similar service) likely caches its database connection string at container startup via an environment variable or a static connection pool. After rotation, the old password is invalid, new connection attempts fail, existing pool connections may still work until recycled, and the symptom is intermittent `authentication failed` errors that appear ~30 days after initial deployment — long after the RDS phase is "done."

**How to avoid:**

Option A (lab-appropriate, no rotation): Do not enable automatic rotation on the Secrets Manager secret. Set a long, randomly generated password and document that it's not rotated. For a lab where the only secret consumer is AccountService, this is acceptable.

Option B (if rotation is required): Use the External Secrets Operator (ESO) or the AWS Secrets Manager CSI Driver to mount the secret as a volume (not an env var). Volume-mounted secrets update in-place without a pod restart when ESO polls Secrets Manager. The app must be written to re-read credentials from disk — verify this before enabling rotation.

**Warning signs:**
- AccountService pods show `authentication failed for user "accountservice"` in logs approximately 30 days after deployment.
- `aws secretsmanager describe-secret` shows `RotationEnabled: true` with no corresponding app-side rotation handling.

**Phase to address:** RDS phase, secrets management design.

---

### [High] engine_version pinned to a deprecated minor (e.g., "14.x" instead of "14.12")

**What goes wrong:**
AWS RDS for PostgreSQL deprecates minor versions on a rolling schedule. If you specify `engine_version = "14"` without the patch level, AWS will pick the latest minor at creation time — but future `terraform plan` runs may show a forced replacement when AWS retires the specific minor the instance was created with. Alternatively, if you pin to a specific minor that's already on the deprecation list, AWS forces an automatic upgrade during the next maintenance window, causing Terraform drift on the version attribute.

**How to avoid:**
Pin to the specific minor version that is currently supported and not end-of-life:

```hcl
resource "aws_db_instance" "accountservice" {
  engine         = "postgres"
  engine_version = "16.3"   # check: aws rds describe-db-engine-versions --engine postgres --query 'DBEngineVersions[?SupportedFeatureNames != `[]`].EngineVersion'
}
```

Check the currently available versions:
```bash
aws rds describe-db-engine-versions \
  --engine postgres \
  --filters Name=status,Values=available \
  --query 'DBEngineVersions[].EngineVersion' \
  --output text
```

**Warning signs:**
- `terraform plan` shows `forces replacement` on `engine_version` after AWS maintenance.
- RDS console shows "Pending maintenance: Engine upgrade."

**Phase to address:** RDS phase, initial instance definition.

---

### [High] Parameter group changes requiring reboot applied during demo usage

**What goes wrong:**
Some RDS PostgreSQL parameter changes (e.g., `max_connections`, `shared_buffers`, `log_min_duration_statement`) have `apply_method = "pending-reboot"`. If Terraform applies a parameter group change without a coordinated reboot, the parameter stays in "pending-reboot" state indefinitely. The app continues running with the old value, and the change is silently deferred until the next maintenance window (or the next AWS-initiated reboot).

**How to avoid:**
For the initial setup, apply the parameter group **before** the RDS instance is created (or during creation). Any subsequent parameter changes:

1. Apply during a window when EasyTrade downtime is acceptable (this is a lab — coordinate with demo users).
2. After `terraform apply`, manually trigger the reboot: `aws rds reboot-db-instance --db-instance-identifier accountservice`.
3. Verify with: `aws rds describe-db-parameters --db-parameter-group-name <name> --query 'Parameters[?IsModifiable==true && ApplyType==`static`]'`

**Warning signs:**
- `aws rds describe-db-instances` shows `"PendingModifiedValues": { "DBParameterGroupName": "..." }`.
- RDS console shows yellow "pending reboot" badge on the parameter group.

**Phase to address:** RDS phase, parameter group definition and any subsequent parameter changes.

---

### [Medium] Migration path from in-cluster Postgres to RDS silently loses data

**What goes wrong:**
EasyTrade's AccountService currently writes to an in-cluster Postgres pod (part of the Helm release). When you provision the RDS instance and update the AccountService connection string to point to RDS, the in-cluster database is abandoned — any accounts, trades, or portfolio data created during previous demos are not automatically migrated. The service starts clean against the empty RDS database. In a live demo, this means missing demo users or "user not found" errors.

**How to avoid:**
Decide explicitly: is a clean slate acceptable? For a lab with synthetic demo data, yes. If demo state must be preserved:

```bash
# From a pod that has psql access to the in-cluster DB
kubectl exec -n easytrade <postgres-pod> -- \
  pg_dump -U postgres accountservice_db > /tmp/accountservice_dump.sql

# Import to RDS
psql -h <rds-endpoint> -U accountservice -d accountservice_db < /tmp/accountservice_dump.sql
```

Then verify row counts match before cutting the connection string over.

**Warning signs:**
- AccountService starts but shows 0 users or empty portfolio after RDS cutover.
- No pg_dump step exists in the migration runbook.

**Phase to address:** RDS phase, cutover checklist.

---

### [Medium] db.t4g.micro burst credit exhaustion under any non-trivial load

**What goes wrong:**
`db.t4g.micro` has a CPU baseline of 10% and earns 12 CPU credits/hour, with a maximum bank of 288 credits (equivalent to ~24 hours of sustained burst). Under any I/O-heavy or CPU-heavy query (unindexed scans, VACUUM, initial data load), credits drain quickly. When the balance hits zero, CPU throttles to 10% — connection establishment slows, query latency spikes, and the AccountService connection pool may time out and crash-loop.

**How to avoid:**
- Create a CloudWatch alarm on `CPUCreditBalance < 50` for the RDS instance.
- Index all foreign keys and columns used in WHERE clauses before the EasyTrade app connects.
- Keep `max_connections` low (default for `db.t4g.micro` is ~34) to avoid connection-pool exhaustion.
- This is a known limitation of the explicit lab cost choice — document it in the runbook.

**Warning signs:**
- CloudWatch `CPUCreditBalance` metric trending toward zero.
- `CPUSurplusCreditsCharged > 0` in CloudWatch (you're being charged for burst beyond the bank).
- AccountService logs show intermittent `connection timeout` or `FATAL: remaining connection slots are reserved` errors.

**Phase to address:** RDS phase, monitoring setup; note as a known constraint in the runbook.

---

## Phase 3 — ArgoCD GitOps Cutover

### [Critical] Ownership conflict: Helm release labels vs. ArgoCD tracking label

**What goes wrong:**
ArgoCD uses `app.kubernetes.io/instance: <argocd-app-name>` (by default) on all managed resources for tracking. The existing `helm_release.easytrade` Terraform resource already stamped all EasyTrade resources with `app.kubernetes.io/instance: easytrade` (Helm's own instance label). When ArgoCD takes ownership and the Application name is also `easytrade`, both labels match — but the tracking mechanism may conflict, causing `SharedResourceWarning` or ArgoCD seeing resources as "out of sync" because Helm metadata (the `sh.helm.sh/chart` annotation and the Helm release secret) is present but not managed by ArgoCD.

ArgoCD does not use `helm install` — it uses `helm template`. This means the existing Helm release secret (`helm.sh/release-v1`) in the `easytrade` namespace is an orphan from ArgoCD's perspective.

**How to avoid:**

1. **Switch ArgoCD resource tracking to annotation mode** (eliminates the label clash entirely):
   In `argocd-cm` ConfigMap, set:
   ```yaml
   application.resourceTrackingMethod: annotation+label
   ```

2. **Delete the Helm release secret before ArgoCD takes ownership:**
   ```bash
   kubectl delete secret -n easytrade \
     -l owner=helm,name=easytrade
   ```
   This removes Helm's ownership record. The resources (Deployments, Services, etc.) remain — only the Helm tracking secret is deleted.

3. **Remove `helm_release.easytrade` from Terraform _before_ creating the ArgoCD Application** (not simultaneously). Run `terraform state rm helm_release.easytrade` to drop it from state without destroying it, then remove the block from HCL.

**Warning signs:**
- ArgoCD Application shows `OutOfSync` immediately after creation, even with an identical chart version and values.
- `kubectl get secret -n easytrade` shows a `helm.sh/release-v1` secret persisting after ArgoCD sync.
- `SharedResourceWarning` in ArgoCD UI for any resource.

**Phase to address:** ArgoCD phase, cutover step before Application creation.

---

### [Critical] auto-sync + auto-prune enabled during cutover — resources get deleted

**What goes wrong:**
If the ArgoCD Application is created with `syncPolicy.automated.prune: true` and the initial `gitops/` chart differs from what Terraform-Helm deployed (e.g., missing a resource that Terraform managed outside the Helm release, like the `kubernetes_ingress_v1.easytrade_ingress`), ArgoCD will **delete** that resource as part of its first sync. The ingress is currently managed by Terraform, not the Helm chart — ArgoCD won't know about it and will prune it.

**How to avoid:**
Enable auto-sync **without** auto-prune during the cutover phase:

```yaml
syncPolicy:
  automated:
    selfHeal: true
    prune: false       # ← off during cutover; enable only after first successful sync is validated
```

Validate the diff manually with `argocd app diff easytrade` before enabling prune. Only turn on `prune: true` after confirming the Application's desired state matches reality.

**Warning signs:**
- ArgoCD `diff` shows resources to be deleted that are known-good infra.
- `kubectl get ingress -n easytrade` returns empty after the first ArgoCD sync.

**Phase to address:** ArgoCD phase, Application manifest authoring.

---

### [Critical] targetRevision: HEAD — tracking the default branch silently

**What goes wrong:**
`targetRevision: HEAD` causes ArgoCD to track the tip of the default branch (`main` or `master`). Every push to that branch — including work-in-progress commits — triggers a sync. There is no stable release artifact. This violates the GitOps principle of explicit, auditable deployments and can cause surprise rollouts mid-demo.

**How to avoid:**
Pin to a specific Git commit SHA or a Git tag for the initial bootstrap. During development, tracking a branch (e.g., `refs/heads/main`) is acceptable only if you understand the implication. For this monorepo, the safe posture is:

```yaml
spec:
  source:
    repoURL: https://github.com/<org>/EKS-Trade.git
    targetRevision: main   # acceptable for a lab; document that any push to main triggers sync
    path: gitops/easytrade
```

The risk in a lab is lower than production, but document explicitly: "any commit to `main` affecting `gitops/` will be auto-synced." Never use `HEAD` as the value — it defaults to whatever the remote considers HEAD, which can change if the default branch is renamed.

**Warning signs:**
- `targetRevision: HEAD` appears in any Application manifest.
- ArgoCD sync history shows syncs triggered by unintended commits (e.g., a docs-only change to `README.md`).

**Phase to address:** ArgoCD phase, gitops/ Application manifest authoring.

---

### [High] Drift between Terraform-deployed state and ArgoCD desired state — perpetual OutOfSync

**What goes wrong:**
The Helm chart version that Terraform deployed without pinning (`version` omitted in `helm_release.easytrade`) is not recorded in Terraform state in a useful way. When the ArgoCD Application points to a specific chart version in `gitops/`, if that version differs from what's running, ArgoCD will try to reconcile. Depending on the diff, this could be destructive (image tags, replica counts, resource limits changed between chart versions).

**How to avoid:**
Before removing `helm_release.easytrade` from Terraform:

1. Find the exact chart version currently running:
   ```bash
   kubectl get secret -n easytrade -l owner=helm,name=easytrade \
     -o jsonpath='{.items[0].metadata.labels.version}'
   # or:
   helm list -n easytrade
   ```
2. Pin that **exact** version in the ArgoCD Application:
   ```yaml
   source:
     chart: easytrade
     repoURL: oci://europe-docker.pkg.dev/dynatrace-demoability/helm
     targetRevision: "1.X.Y"   # must match what's running
   ```
3. Do the first sync with the matched version. Only then upgrade the chart version deliberately.

**Warning signs:**
- ArgoCD Application stuck in `OutOfSync` with a diff showing container image tag changes.
- `argocd app diff easytrade` shows unexpected resource mutations.

**Phase to address:** ArgoCD phase, pre-cutover discovery step.

---

### [High] ArgoCD CRD leftovers blocking reinstall

**What goes wrong:**
If ArgoCD is installed, then uninstalled (e.g., to change the install method or fix a misconfiguration), the CRDs (`applications.argoproj.io`, `appprojects.argoproj.io`, etc.) may be left behind. On reinstall, Helm won't upgrade CRDs (Helm never deletes or modifies CRDs on upgrade). If the new ArgoCD version has updated CRD schemas, the old CRDs shadow the new ones, causing subtle runtime errors or Application reconciliation failures.

**How to avoid:**
On any ArgoCD reinstall, explicitly delete the CRDs first:

```bash
kubectl get crd | grep argoproj.io | awk '{print $1}' | xargs kubectl delete crd
```

This will also delete all `Application` and `AppProject` resources (cascade delete). Back up Application manifests first:
```bash
kubectl get application -n argocd -o yaml > argocd-apps-backup.yaml
```

**Warning signs:**
- `helm upgrade argocd` completes but `kubectl describe crd applications.argoproj.io` shows an old version annotation.
- ArgoCD UI shows Applications from a previous install that "shouldn't exist."

**Phase to address:** ArgoCD phase, if reinstall is ever required.

---

### [High] Finalizers causing stuck ArgoCD Application deletion

**What goes wrong:**
ArgoCD Applications have a `resources-finalizer.argocd.argoproj.io` finalizer that triggers cascade deletion of all managed Kubernetes resources when the Application is deleted. If the ArgoCD controller is down (e.g., during a reinstall, namespace deletion, or Terraform destroy), the finalizer is never processed, and the Application resource stays in `Terminating` state indefinitely, blocking namespace cleanup.

**How to avoid:**
During any planned removal of the ArgoCD Application:

```bash
# Remove the finalizer before deleting (non-cascade, resources stay in cluster)
kubectl patch application easytrade -n argocd \
  --type merge -p '{"metadata":{"finalizers":null}}'

kubectl delete application easytrade -n argocd
```

If already stuck:
```bash
kubectl get application easytrade -n argocd -o json \
  | jq 'del(.metadata.finalizers)' \
  | kubectl replace --raw /apis/argoproj.io/v1alpha1/namespaces/argocd/applications/easytrade -f -
```

**Warning signs:**
- `kubectl get application -n argocd` shows an application with `DeletionTimestamp` set but not gone after 5+ minutes.
- ArgoCD UI shows the Application as "Deleting" indefinitely.

**Phase to address:** ArgoCD phase, any teardown or reinstall procedure.

---

### [Medium] Unpinned Helm chart version in Application spec — surprise updates

**What goes wrong:**
If the ArgoCD Application uses `targetRevision: "*"` or omits the chart version for an OCI Helm source, ArgoCD may resolve to a newer chart version on the next sync, silently updating EasyTrade without a Git commit. This is the same problem as the original unpinned `helm_release.easytrade` but now hidden in the Application spec.

**How to avoid:**
Always pin the chart version explicitly in `gitops/easytrade/Application.yaml`:

```yaml
spec:
  source:
    chart: easytrade
    repoURL: oci://europe-docker.pkg.dev/dynatrace-demoability/helm
    targetRevision: "1.X.Y"   # never "*", never omitted
```

Chart version bumps must be explicit Git commits — that's the point of GitOps.

**Warning signs:**
- `targetRevision` in the Application spec is `*`, `latest`, or empty.
- `argocd app history easytrade` shows version changes that don't correspond to Git commits.

**Phase to address:** ArgoCD phase, Application manifest definition.

---

### [Medium] Sync-wave / hook ordering when Terraform manages infra and ArgoCD manages app

**What goes wrong:**
The ArgoCD Application for EasyTrade may include resources that depend on infra provisioned by Terraform (e.g., an RDS secret injected as a Kubernetes Secret, a ConfigMap with the RDS endpoint). If ArgoCD syncs before Terraform has applied the RDS phase, AccountService starts with an empty or missing secret, fails to connect, and crash-loops. ArgoCD marks the sync as "Healthy" because the Deployment is running — but the pods are restarting in the background.

**How to avoid:**
Establish a clear sequencing rule in the runbook: **Terraform applies (RDS, Dynatrace) must complete before the ArgoCD Application is synced.** During the ArgoCD phase, use `argocd app sync --dry-run` to inspect what will change before the first live sync. Do not use `auto-sync` during the initial setup window.

**Warning signs:**
- AccountService pods crash-loop with `connection refused` or `secret not found` errors immediately after ArgoCD sync.
- `kubectl get secret -n easytrade accountservice-db-credentials` returns `NotFound`.

**Phase to address:** ArgoCD phase, sequencing with RDS phase output.

---

## Phase 4 — Dynatrace Operator

### [Critical] Operator token with missing scopes — DynaKube stuck in error state

**What goes wrong:**
The Dynatrace Operator requires specific token scopes. If any scope is missing, the DynaKube CR enters an error state with an unhelpful message like `"operator token is invalid"` or `"failed to pull installer"`, and no OneAgent pods are created. The full required scope list for the **operator token** (as of Operator 0.9+):

- `InstallerDownload` (PaaS / `paasTokenScopes`)
- `settings.read` (API v2)
- `settings.write` (API v2)
- `activeGateTokenManagement.create` (API v2)

For the **data ingest token**:
- `metrics.ingest` (API v2)
- `logs.ingest` (API v2)
- `openTelemetryTrace.ingest` (API v2)

**How to avoid:**
Use the Dynatrace UI token creation wizard with the template **"Kubernetes: Dynatrace Operator"** — it pre-selects the correct scopes. Do not create tokens manually scope-by-scope without verifying against the [current docs](https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/tokens-permissions).

Verify before applying the DynaKube CR:
```bash
# Validate operator token from the cluster side
kubectl -n dynatrace describe dynakube <name>
# Look for "conditions" with type=TokenConditionType
```

Store tokens in AWS Secrets Manager or SSM Parameter Store; inject as a Kubernetes Secret:
```bash
kubectl create secret generic dynakube-operator \
  -n dynatrace \
  --from-literal=apiToken=<operator-token> \
  --from-literal=dataIngestToken=<ingest-token>
```

**Warning signs:**
- `kubectl describe dynakube -n dynatrace` shows condition `APITokenConditionType: error`.
- Operator logs: `"failed to pull installer: 401 Unauthorized"`.
- No OneAgent DaemonSet created in the cluster 5+ minutes after DynaKube apply.

**Phase to address:** Dynatrace phase, token provisioning step.

---

### [Critical] DynaKube CR applied before Operator CRDs are fully registered

**What goes wrong:**
The Dynatrace Operator is installed via a Helm chart (via Terraform `helm_release`). Helm returns success after the chart objects are submitted to the Kubernetes API, but the CRD registration is asynchronous. If a `kubectl apply -f dynakube.yaml` or a second Terraform resource tries to create the DynaKube CR before the `dynakubes.dynatrace.com` CRD is registered, it fails with `no matches for kind "DynaKube" in version "dynatrace.com/v1beta3"`.

**How to avoid:**
If creating the DynaKube CR via Terraform (using `kubernetes_manifest`), add an explicit `depends_on` on the `helm_release` and increase the `helm_release` timeout:

```hcl
resource "helm_release" "dynatrace_operator" {
  name      = "dynatrace-operator"
  # ...
  wait      = true          # wait for operator Deployment to be Ready
  timeout   = 300           # 5 minutes for CRD registration + operator pod startup
}

resource "kubernetes_manifest" "dynakube" {
  depends_on = [helm_release.dynatrace_operator]
  # ...
}
```

Alternatively, apply the operator and DynaKube in two separate `terraform apply` invocations using `-target`:
```bash
terraform apply -target=helm_release.dynatrace_operator
# wait 30s, then:
terraform apply -target=kubernetes_manifest.dynakube
```

**Warning signs:**
- `terraform apply` fails with `Error: no matches for kind "DynaKube"` during the DynaKube resource creation.
- `kubectl get crd dynakubes.dynatrace.com` returns `NotFound` immediately after operator install.

**Phase to address:** Dynatrace phase, Terraform resource ordering.

---

### [Critical] Tenant URL format mismatch — apps.dynatrace.com vs. live.dynatrace.com

**What goes wrong:**
The DynaKube CR requires the `spec.apiUrl` to be the **API endpoint**, not the browser UI URL. For SaaS tenants:

- Browser UI: `https://<tenant-id>.apps.dynatrace.com`
- **Correct `apiUrl`**: `https://<tenant-id>.live.dynatrace.com/api`

Using the `apps.dynatrace.com` URL in `apiUrl` causes the Operator to fail API calls with 404 or 403, and OneAgent never registers with the tenant.

**How to avoid:**
Set `spec.apiUrl` explicitly:

```yaml
spec:
  apiUrl: https://<tenant-id>.live.dynatrace.com/api
```

Verify the URL is reachable from a pod in the cluster before applying DynaKube:
```bash
kubectl run -it --rm curl-test --image=curlimages/curl --restart=Never -- \
  curl -s -o /dev/null -w "%{http_code}" \
  https://<tenant-id>.live.dynatrace.com/api/v1/time
# expect 200
```

**Warning signs:**
- `kubectl describe dynakube -n dynatrace` shows `APIEndpointConditionType: error`.
- Operator logs: `"failed to query API: 404 Not Found"` or `"connection refused"`.
- No hosts appear in the Dynatrace tenant's Kubernetes observability view.

**Phase to address:** Dynatrace phase, DynaKube CR authoring.

---

### [High] OneAgent init container injection breaking pods with restrictive securityContext

**What goes wrong:**
Dynatrace cloud-native or classic full-stack injection adds an init container to every instrumented pod. If the pod has a `securityContext` with `readOnlyRootFilesystem: true` or a restrictive `seccompProfile`, the init container may fail to write the agent binaries to the shared volume, causing the pod to crash-loop before the application container starts. This is especially relevant for EasyTrade services that may have hardened security contexts.

**How to avoid:**
Check EasyTrade's Helm chart values for any `securityContext` settings before enabling injection. The `classicFullStack` mode is more invasive than `applicationMonitoring` (webhook-based). For this lab:

- Use `cloudNativeFullStack` (recommended for EKS EC2) — it uses a CSI driver for code module injection, which is less likely to conflict with restrictive security contexts than the classic DaemonSet approach.
- Or scope injection to specific namespaces only (see namespace monitoring pitfall below).

```yaml
spec:
  oneAgent:
    cloudNativeFullStack:
      tolerations:
        - effect: NoSchedule
          key: node-role.kubernetes.io/control-plane
          operator: Exists
```

**Warning signs:**
- EasyTrade pods crash-loop with `Init:Error` or `Init:CrashLoopBackOff` after DynaKube is applied.
- `kubectl describe pod <pod> -n easytrade` shows the `install-oneagent` init container failing.

**Phase to address:** Dynatrace phase, DynaKube CR configuration.

---

### [High] Monitoring all namespaces by default — kube-system noise and cost

**What goes wrong:**
By default, the DynaKube CR instruments all namespaces. This includes `kube-system`, `kube-public`, `argocd`, and `dynatrace` itself. kube-system injection can interfere with system components (CoreDNS, kube-proxy DaemonSets), generate monitoring noise, and inflate Dynatrace host unit (DHU) or DDU consumption for the tenant.

**How to avoid:**
Scope injection to the `easytrade` namespace only using the namespace selector:

```yaml
spec:
  namespaceSelector:
    matchLabels:
      dynatrace-inject: "true"
```

Then label only the target namespace:
```bash
kubectl label namespace easytrade dynatrace-inject=true
```

Or use a blocklist to exclude system namespaces:
```yaml
spec:
  oneAgent:
    cloudNativeFullStack:
      namespaceSelector:
        matchExpressions:
          - key: kubernetes.io/metadata.name
            operator: NotIn
            values: [kube-system, kube-public, dynatrace, argocd]
```

**Warning signs:**
- Dynatrace tenant shows unexpected hosts/processes from `kube-system` components.
- CoreDNS pods restart after DynaKube is applied.
- DDU consumption in the Dynatrace tenant is higher than expected for the lab workload.

**Phase to address:** Dynatrace phase, DynaKube CR configuration.

---

### [High] ActiveGate egress blocked — no connectivity to Dynatrace SaaS

**What goes wrong:**
The EKS cluster's private subnets route internet traffic through a NAT Gateway. If the NAT Gateway's route table, a VPC security group, or an AWS Network Firewall rule blocks outbound HTTPS to `*.live.dynatrace.com` (port 443), the ActiveGate pod cannot reach the Dynatrace SaaS endpoint. The operator will appear healthy (pod Running), but no data flows to the tenant.

**How to avoid:**
Before applying DynaKube, verify egress from inside the cluster:

```bash
kubectl run -it --rm curl-test --image=curlimages/curl --restart=Never -n easytrade -- \
  curl -sv https://<tenant-id>.live.dynatrace.com/api/v1/time
```

Ensure the VPC's NAT Gateway is operational and the route table for private subnets has `0.0.0.0/0 → nat-xxxxxxxx`.

**Warning signs:**
- ActiveGate pod is `Running` but no hosts appear in the Dynatrace tenant.
- Operator logs: `"connection refused"` or `"i/o timeout"` when calling the Dynatrace API.
- `curl` from a pod in the cluster to `live.dynatrace.com` times out.

**Phase to address:** Dynatrace phase, pre-install network verification.

---

### [Medium] Token rotation breaking OneAgent → DynaKube reconcile

**What goes wrong:**
If the operator token stored in the `dynakube-operator` Kubernetes Secret is rotated (new token generated in Dynatrace, old token revoked) without updating the Kubernetes Secret, the Operator's next reconciliation loop will fail. The OneAgent DaemonSet continues running (already deployed pods keep working), but the Operator cannot check for updates, apply new configurations, or report health back to the tenant. This can go unnoticed for days.

**How to avoid:**

1. Do not enable automatic token rotation in Dynatrace for the operator token unless you have automation to simultaneously update the Kubernetes Secret.
2. If rotation is required, use AWS Secrets Manager + External Secrets Operator: ESO syncs the rotated token to the Kubernetes Secret automatically within the poll interval.
3. After any manual token rotation, immediately update the Secret and force a DynaKube reconcile:
   ```bash
   kubectl rollout restart deployment dynatrace-operator -n dynatrace
   ```

**Warning signs:**
- Dynatrace tenant shows the cluster as "disconnected" or "last seen > 24h ago."
- Operator logs: `"401 Unauthorized"` on reconcile loop calls.

**Phase to address:** Dynatrace phase, secrets management design.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| `publicly_accessible = false` by default-reliance (not explicit) | Fewer lines | Next engineer doesn't know if it was intentional | Never — always explicit |
| Skipping `deletion_protection = true` on RDS | Simpler `terraform destroy` in dev | One stray destroy command loses all DB data | Never for a pilot RDS instance |
| `targetRevision: HEAD` in ArgoCD Application | Works immediately, no SHA to manage | Every commit to main deploys to cluster | Lab-only, documented |
| Broad namespace monitoring in Dynatrace (all namespaces) | Zero-config full visibility | kube-system injection noise, cost overrun | Never — always scope |
| `encrypt = true` without CMK (AES256 SSE-S3) | Avoids KMS complexity | Less auditability per-key, no key rotation control | Acceptable for a lab |
| RDS with no automated snapshot retention period set | Default behavior | Default is 7 days — fine for a lab, silent | Acceptable for a lab |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Terraform S3 backend → AWS IAM | Using `aws configure` credentials that differ from what's in the backend block's region assumption | Set `AWS_PROFILE` or `AWS_DEFAULT_REGION` explicitly before `terraform init` |
| ArgoCD → OCI Helm registry (GCP Artifact Registry) | Forgetting to configure repository credentials for a private OCI registry in ArgoCD | Add `argocd repo add oci://europe-docker.pkg.dev/dynatrace-demoability/helm --type helm --enable-oci` if the registry requires auth |
| Dynatrace Operator → Kubernetes Secret | Double-encoding the token (base64 in Terraform, Kubernetes also base64-encodes secrets) | Use `kubernetes_secret` resource with raw string values — Terraform's provider handles encoding |
| RDS → EKS pods | Injecting the RDS endpoint as an env var at pod creation time — endpoint never changes but feels fragile | Use AWS Secrets Manager CSI Driver or ESO to mount the connection string; allows rotation without redeployment |
| ArgoCD Application → Terraform-managed Ingress | ArgoCD doesn't know about the `kubernetes_ingress_v1` managed by Terraform; prune deletes it | Either move the ingress into `gitops/` or annotate it with `argocd.argoproj.io/managed-by` to declare it out-of-scope |

---

## "Looks Done But Isn't" Checklist

- [ ] **State migration:** `terraform plan` after migration shows zero diff — not just "init succeeded."
- [ ] **State migration:** Local `terraform.tfstate` and `*.tfstate.backup` files are deleted from the working directory.
- [ ] **RDS:** `aws rds describe-db-instances` shows `DeletionProtection: true` and `PubliclyAccessible: false`.
- [ ] **RDS:** SG inbound rule for 5432 references the EKS SG ID, not a CIDR block.
- [ ] **RDS:** AccountService can actually connect — not just "RDS status: available."
- [ ] **ArgoCD:** Application shows `Synced` and `Healthy` — not just `Synced`.
- [ ] **ArgoCD:** The Helm release secret (`sh.helm.sh/chart`) is gone from the `easytrade` namespace.
- [ ] **ArgoCD:** `helm list -n easytrade` returns empty (Terraform no longer manages the release).
- [ ] **Dynatrace:** Hosts appear in the Dynatrace tenant's Kubernetes observability — not just "Operator pod Running."
- [ ] **Dynatrace:** EasyTrade traces are visible in Distributed Tracing — not just infrastructure metrics.
- [ ] **Dynatrace:** `kubectl describe dynakube -n dynatrace` shows all conditions `True` with no errors.

---

## Pitfall-to-Phase Mapping

| Pitfall | Severity | Phase | Verification |
|---------|----------|-------|--------------|
| Chicken-and-egg bucket bootstrap | Critical | State-migration | `terraform init` succeeds; `aws s3 ls s3://eks-trade-tfstate-*` shows state key |
| Stale local state after migration | Critical | State-migration | `ls terraform.tfstate*` returns nothing |
| Committing `*.tfstate.backup` | Critical | State-migration | `git ls-files | grep tfstate` returns nothing |
| Missing DynamoDB lock permissions | High | State-migration | `terraform apply` acquires and releases lock cleanly |
| KMS key policy denying execution role | High | State-migration | `terraform plan` succeeds with `encrypt = true` |
| OneDrive sync race | Medium | State-migration | OneDrive paused during migration window |
| delete_protection + prevent_destroy missing | Critical | RDS | `aws rds describe-db-instances` shows `DeletionProtection: true` |
| SG rules allow-all instead of cluster SG | Critical | RDS | SG rule source is a SG ID, not CIDR |
| subnet_group in public subnets | Critical | RDS | Subnet IDs match `np-lab-Private-*` tag |
| publicly_accessible = true | High | RDS | `PubliclyAccessible: false` in describe output |
| Credentials rotation breaks app | High | RDS | Rotation disabled or ESO-based rotation plan documented |
| Deprecated engine_version minor | High | RDS | `engine_version` pinned to a currently-available minor |
| Parameter group reboot during demo | High | RDS | Parameter changes applied in a scheduled window |
| Silent data loss on Postgres migration | Medium | RDS | pg_dump/restore or explicit "clean slate" decision documented |
| db.t4g.micro burst exhaustion | Medium | RDS | `CPUCreditBalance` CloudWatch alarm configured |
| Helm vs ArgoCD tracking label conflict | Critical | ArgoCD | Helm release secret deleted; ArgoCD uses annotation tracking |
| auto-prune deletes infra during cutover | Critical | ArgoCD | `prune: false` during cutover; enabled only after manual diff validation |
| targetRevision: HEAD tracking | Critical | ArgoCD | Application manifest shows a branch ref, documented |
| Perpetual OutOfSync from chart version drift | High | ArgoCD | `argocd app diff easytrade` shows no diff before first sync |
| CRD leftovers blocking reinstall | High | ArgoCD | `kubectl get crd | grep argoproj` shows current version only |
| Finalizers causing stuck Application deletion | High | ArgoCD | Runbook includes `kubectl patch … finalizers:null` command |
| Unpinned chart version in Application | Medium | ArgoCD | `targetRevision` in Application spec is a semantic version string |
| Sync-wave ordering: Terraform vs ArgoCD | Medium | ArgoCD | Runbook enforces Terraform-first sequencing |
| Operator token missing scopes | Critical | Dynatrace | `kubectl describe dynakube` shows all conditions True |
| DynaKube CR before CRD registered | Critical | Dynatrace | `wait = true` + `depends_on` in Terraform; or two-stage apply |
| Tenant URL format mismatch | Critical | Dynatrace | `curl` from pod to `<tenant>.live.dynatrace.com/api/v1/time` returns 200 |
| Init container injection + restrictive securityContext | High | Dynatrace | EasyTrade pods start cleanly after DynaKube is applied |
| Monitoring all namespaces by default | High | Dynatrace | `namespaceSelector` scopes to `easytrade` only |
| ActiveGate egress blocked | High | Dynatrace | `curl` from pod to Dynatrace API returns 200 pre-install |
| Token rotation breaking reconcile | Medium | Dynatrace | No automatic token rotation; or ESO sync configured |

---

## Sources

- Terraform S3 backend docs: https://developer.hashicorp.com/terraform/language/backend/s3
- Terraform state migration: https://support.hashicorp.com/hc/en-us/articles/44027197997587
- Chicken-and-egg bootstrap: https://discuss.hashicorp.com/t/chicken-and-egg-the-terraform-remote-state-s3-bucket-cannot-be-idempotent-if-created-by-terraform/21880
- Terraform S3 native locking (1.11 GA): https://medium.com/aws-specialists/dynamodb-not-needed-for-terraform-state-locking-in-s3-anymore-29a8054fc0e9
- RDS + EKS SG connectivity: https://dev.to/stack-labs/securing-the-connectivity-between-amazon-eks-and-amazon-rds-part-2-5glb
- RDS burst credits exhaustion: https://repost.aws/knowledge-center/rds-low-burst-balance
- Secrets Manager rotation + EKS: https://medium.com/@govind_sharma/seamless-rds-password-rotation-in-eks-without-restarting-pods-9c65130d0359
- AWS prescriptive guidance: rotate without restarting containers: https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/rotate-database-credentials-without-restarting-containers.html
- ArgoCD auto-sync/prune docs: https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/
- ArgoCD resource tracking: https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/
- ArgoCD tracking method conflict: https://github.com/argoproj/argo-cd/issues/18411
- ArgoCD finalizers: https://codefresh.io/blog/argocd-application-deletion-finalizers/
- ArgoCD anti-patterns: https://codefresh.io/blog/argo-cd-anti-patterns-for-gitops/
- ArgoCD targetRevision strategies: https://argo-cd.readthedocs.io/en/latest/user-guide/tracking_strategies/
- Dynatrace Operator token scopes: https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/tokens-permissions
- DynaKube parameters: https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/reference/dynakube-parameters
- Dynatrace cloud-native vs classic: https://docs.dynatrace.com/docs/ingest-from/setup-on-k8s/deployment/full-stack-observability
- Dynatrace K8s tips (AKS + policy): https://romikoderbynew.com/2025/10/15/dynatrace-on-kubernetes-tips-from-the-trenches-aks-gatekeeper-policy/
- CRD/CR race in Terraform: https://github.com/hashicorp/terraform-provider-kubernetes/issues/1367
- KMS key policy for Terraform state: https://keita.blog/2017/02/21/iam-policy-for-kms-encrypted-remote-terraform-state-in-s3/

---
*Pitfalls research for: EKS lab hardening — S3/DynamoDB backend, RDS pilot, ArgoCD GitOps, Dynatrace Operator*
*Researched: 2026-04-20*
