# TradeStorm

> A single-file Terraform stack that deploys the Dynatrace **EasyTrade** demo on AWS EKS — backed by a managed **RDS SQL Server**, observable via CloudWatch, and reskinned with a custom CSS overlay served from an nginx sub_filter sidecar. End-to-end reproducible from one `terraform apply`.

[![Open Source](https://img.shields.io/badge/Open%20Source-%E2%9D%A4-brightgreen.svg)](LICENSE)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/roy-asraf1/TradeStorm/pulls)
[![Terraform](https://img.shields.io/badge/Terraform-1.5%2B-7B42BC?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![AWS](https://img.shields.io/badge/AWS-us--east--1-FF9900?logo=amazonaws&logoColor=white)](https://aws.amazon.com/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.34-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![SQL Server](https://img.shields.io/badge/SQL_Server-2022_Express-CC2927?logo=microsoftsqlserver&logoColor=white)](https://www.microsoft.com/sql-server)

> **TradeStorm is free and open source software.** The Terraform code in this repository is released under the permissive [MIT License](LICENSE) — you are free to use, copy, modify, fork, and redistribute it, including in commercial settings. Contributions and forks are welcome.

---

## What's in this repository (and what isn't)

This repo is **infrastructure-as-code only**. It contains:

- `main.tf` — the Terraform stack (the work authored here)
- `README.md` — this file
- `LICENSE` — MIT, covers the Terraform code only
- `.gitignore`, `.terraform.lock.hcl` — supporting files

It does **not** contain:

- The **EasyTrade** application source, container images, or Helm chart — those are owned by **Dynatrace** and pulled at deploy time from their public OCI registry (`oci://europe-docker.pkg.dev/dynatrace-demoability/helm`). Nothing of theirs is redistributed through this repo.
- **SQL Server** — provisioned through AWS RDS license-included; not redistributed here.
- Any **Terraform state** — `terraform.tfstate*` is gitignored because it contains generated secrets (RDS password, ARNs).

When you run `terraform apply`, the chart and all upstream images are downloaded directly from their original sources to your cluster.

---

## Who is this project for

This stack was built with very specific people in mind. If you recognize yourself in any of these, you're in the right place:

- **Observability / APM engineers** who need a realistic, always-on workload that produces continuous, *organic* traffic across multiple services and a real database — for testing Dynatrace, Datadog, New Relic, AWS CloudWatch, OTel collectors, etc. Turn the loadgen on and walk away; the system pumps DB connections, HTTP calls, queue messages, and SQL queries 24/7.
- **SRE / platform engineers** evaluating EKS + managed-RDS patterns: how to wire a Helm chart that ships its own DB to an external RDS without forking the chart, how to do schema bootstrap as a one-shot Job, how to roll only the relevant deployments after a Secret swap.
- **Cloud architects designing demo environments** for stakeholder presentations — a non-trivial microservice topology (17 services, a queue, a real RDS) that boots in 25 minutes and can be torn down with one command.
- **Engineers learning EKS, RDS, ALB, IRSA, and Helm** through a real, end-to-end example rather than a Hello-World cluster.
- **Security / FinOps teams** who want a sandbox to test policies (SG rules, IAM scoping, cost controls) against a workload that resembles a real app.
- **People who want to play with EasyTrade** without rebuilding every container image — the included CSS injection sidecar shows how to reskin a vendor SPA at the network layer.

> **Primary use case observed in practice:** continuous synthetic traffic for monitoring tools. Flip `loadgen.enabled = true`, walk away, and your CloudWatch / Dynatrace dashboards fill up with realistic patterns within minutes.

---

## Step-by-step setup

This walkthrough takes you from a clean machine to a running app. Skip steps you've already done.

### Step 1 — Install the local tools

You need three things on your laptop:

```bash
# macOS (Homebrew)
brew install terraform awscli kubectl

# Linux (apt-based)
sudo apt-get update
sudo apt-get install -y curl unzip
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install -y terraform
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o aws.zip && unzip aws.zip && sudo ./aws/install
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

Verify each:

```bash
terraform version    # need >= 1.5
aws --version        # any recent v2 is fine
kubectl version --client
```

### Step 2 — Configure AWS credentials

You need an IAM user or role with permissions for **EKS, EC2, IAM, RDS, ELB, CloudFormation, KMS**. The simplest path:

```bash
aws configure
# AWS Access Key ID:     <your access key>
# AWS Secret Access Key: <your secret>
# Default region:        us-east-1
# Default output format: json
```

Sanity check:

```bash
aws sts get-caller-identity
# Should return your Account ID, ARN, and UserId.
```

If you use SSO instead:

```bash
aws configure sso
# follow the prompts, then:
export AWS_PROFILE=<your-profile-name>
```

### Step 3 — Confirm the target VPC exists

The stack assumes an existing VPC named `np-lab` with private subnets matching `np-lab-Private-*`. The VPC ID is **hardcoded** in `main.tf` (`vpc-01ef4e3d50795d273`). Verify it's reachable:

```bash
aws ec2 describe-vpcs --vpc-ids vpc-01ef4e3d50795d273 --region us-east-1 \
  --query 'Vpcs[0].{Id:VpcId,Cidr:CidrBlock,State:State}'
```

If you get an error or this is a different account, edit lines 38–51 of `main.tf`:

```hcl
data "aws_vpc" "existing" {
  id = "vpc-XXXXXXXXXXXXX"   # ← your VPC ID
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
  filter {
    name   = "tag:Name"
    values = ["YOUR-PRIVATE-SUBNET-PATTERN-*"]   # ← your subnet tag pattern
  }
}
```

### Step 4 — Clone the repo

```bash
git clone https://github.com/roy-asraf1/TradeStorm.git
cd TradeStorm
```

### Step 5 — Verify line endings

The schema-init Job runs `bash` inside a container; Windows-style CRLF leaks into the heredoc and breaks `set -eo pipefail`. If you cloned on macOS/Linux you're fine. On Windows, run:

```bash
file main.tf      # should say "Unicode text, UTF-8 text" (no "CRLF")

# If it says CRLF:
tr -d '\r' < main.tf > main.tf.tmp && mv main.tf.tmp main.tf
```

### Step 6 — Initialize Terraform

This downloads the AWS, Kubernetes, Helm, and Random providers, plus the EKS and EKS-Blueprints-Addons modules:

```bash
terraform init
```

You should see:

```
Initializing the backend...
Initializing modules...
Initializing provider plugins...
Terraform has been successfully initialized!
```

### Step 7 — Preview the plan

```bash
terraform plan
```

Read it. On a clean run it'll show **~80–100 resources to create** (EKS components, IAM roles, RDS, the Helm release, etc.). If you see anything destroying production state, **stop and investigate**.

### Step 8 — Apply

```bash
terraform apply
# type "yes" when prompted, or use:
terraform apply -auto-approve
```

This is the long step. Expected timing:

| Phase | Duration |
|---|---:|
| EKS control plane creation | ~12 min |
| Node group + addons | ~5 min |
| ALB Controller install | ~2 min |
| Helm release (EasyTrade) | ~2 min |
| RDS provisioning (in parallel) | ~13 min |
| Schema init Job + secret swap + rollout | ~30 sec |
| **Total wall clock** | **~25–30 min** |

If the schema-init Job fails with `BackoffLimitExceeded`, see [Troubleshooting](#troubleshooting).

### Step 9 — Configure kubectl

After apply finishes, point `kubectl` at the new cluster:

```bash
aws eks update-kubeconfig --region us-east-1 --name easytrade-lab
kubectl get nodes
# NAME                          STATUS   ROLES    AGE   VERSION
# ip-10-0-XXX-XXX.ec2.internal  Ready    <none>   5m    v1.34.X
kubectl get pods -n easytrade
# 17 services + 1 db + 1 rabbitmq + 2 skin pods, all Running
```

### Step 10 — Get the app URL and open it

```bash
terraform output alb_dns_name
# → http://k8s-easytrad-easytrad-XXXXXXXXX.us-east-1.elb.amazonaws.com
```

Paste it into a browser. You'll see the EasyTrade SPA wearing the custom theme.

> **Heads up:** the ALB DNS takes another 60–90 seconds to fully propagate after `terraform apply` returns. If you get a DNS error, wait and retry.

### Step 11 — Confirm writes are hitting RDS

The single most reassuring check that this isn't smoke and mirrors:

```bash
RDS_HOST=$(terraform output -raw easytrade_db_endpoint)
RDS_PASS=$(terraform state pull | python3 -c \
  "import json,sys;d=json.load(sys.stdin);[print(r['instances'][0]['attributes']['result']) \
   for r in d['resources'] if r.get('type')=='random_password' and r.get('name')=='easytrade_db']")

kubectl run rds-check --rm -i --restart=Never -n easytrade \
  --image=europe-docker.pkg.dev/dynatrace-demoability/docker/easytrade/db:1.3.16 \
  --env="RDS_HOST=$RDS_HOST" --env="RDS_PASS=$RDS_PASS" \
  --command -- /opt/mssql-tools/bin/sqlcmd -S "${RDS_HOST},1433" \
  -U easytradeadmin -P "$RDS_PASS" -d TradeManagement \
  -Q "SELECT host_name, program_name, COUNT(*) AS sessions
      FROM sys.dm_exec_sessions
      WHERE database_id = DB_ID('TradeManagement')
      GROUP BY host_name, program_name"
```

You should see active sessions from `easytrade-manager-*` and `easytrade-pricing-service-*` pods.

### Step 12 — (Optional) Turn on the load generator

If your reason for being here is "continuous traffic for monitoring," now's the time:

```hcl
# main.tf — change "false" → "true"
set {
  name  = "loadgen.enabled"
  value = "true"
}
```

```bash
terraform apply
```

Within 90 seconds, RDS metrics start moving. Within 5 minutes you have realistic, sustained load patterns visible in CloudWatch and any APM tool you have attached.

### Step 13 — When you're done, tear it all down

```bash
terraform destroy
```

Order: skin pods → ingress → ALB → RDS → node group → control plane → IAM. Total: ~15 minutes. The `np-lab` VPC is untouched.

---

## Architecture

```
                   ┌─────────────────────────────────────────────────┐
                   │                Internet                         │
                   └────────────────────┬────────────────────────────┘
                                        │ HTTP :80
                                        ▼
                          ┌──────────────────────────────┐
                          │  Application Load Balancer   │  ← ALB Ingress Controller
                          │  (internet-facing, IP-based) │     (eks-blueprints-addons)
                          └────────────────┬─────────────┘
                                           │
                  ┌────────────────────────┴──────────────────────────┐
                  │                                                    │
                  │   ╔═══════════════════════════════════════════╗   │
                  │   ║      easytrade-skin (nginx, x2)           ║   │ ← custom CSS injection
                  │   ║      sub_filter '</head>' → +<link>       ║   │   via ConfigMap
                  │   ╚═══════════════════════════════════════════╝   │
                  │                       │                            │
                  │                       ▼                            │
                  │   ┌──────────────────────────────────────────┐    │
                  │   │  easytrade-frontendreverseproxy (nginx)  │    │
                  │   │  routes /api/* and SPA assets            │    │
                  │   └──────┬───────────────────────────┬───────┘    │
                  │          │                           │            │
                  │  ┌───────▼──────┐         ┌──────────▼──────────┐ │
                  │  │  frontend    │         │ accountservice      │ │
                  │  │  (SPA, React)│         │ loginservice        │ │
                  │  └──────────────┘         │ broker-service      │ │
                  │                           │ pricing-service     │ │
                  │                           │ contentcreator      │ │
                  │                           │ credit-card-service │ │
                  │                           │ manager (orch.)     │ │
                  │                           │ + 5 more services   │ │
                  │                           └──────────┬──────────┘ │
                  │   EKS  (easytrade-lab,  k8s 1.34)               │
                  └──────────────────────────────────────┬──────────┘
                                                         │
                                                         │ TCP 1433
                                                         │ (Java/Go/.NET drivers)
                                                         ▼
                                       ┌────────────────────────────────┐
                                       │   RDS SQL Server 2022 Express  │
                                       │   db.t3.small, license-included│
                                       │   Database: TradeManagement    │
                                       │   Private subnet only          │
                                       └────────────────────────────────┘
```

**Network notes:**
- ALB lives in the public subnets of the existing `np-lab` VPC.
- EKS nodes run in private subnets, NAT'd for image pulls.
- RDS is private-only (`publicly_accessible = false`); only the EKS node Security Group can reach port 1433.
- All inter-service traffic stays inside the VPC.

---

## What gets deployed

| Layer | Resource | Notes |
|---|---|---|
| **Compute** | EKS cluster `easytrade-lab` (k8s 1.34) | Managed control plane |
| | Node group `standard` (1× t3.xlarge SPOT) | min=1, max=2, desired=1 |
| | EKS addon `kube-proxy` | Auto-resolved to latest compatible version |
| | IRSA (OIDC provider) | For controller IAM roles |
| **Network** | Existing VPC `np-lab` | `vpc-01ef4e3d50795d273` |
| | ALB Ingress Controller | Via `eks-blueprints-addons` |
| | Ingress (internet-facing) | Health check: `GET /api/Login` → 200 |
| **Application** | EasyTrade Helm release (`v1.3.16`) | OCI chart from Dynatrace registry |
| | 17 service deployments + StatefulSet (idle) | rabbitmq, manager, services, etc. |
| | `easytrade-skin` Deployment (×2) | nginx with sub_filter CSS injection |
| | ConfigMap `easytrade-skin` | nginx.conf + 7.5KB skin.css |
| **Data** | RDS SQL Server Express `easytrade-db` | db.t3.small, 20GB gp3, port 1433 |
| | DB subnet group + Security Group | Ingress only from EKS node SG |
| | Init Job `init-rds-schema` | Runs the chart's own SQL scripts against RDS |
| | `kubernetes_secret_v1_data` override | Patches 3 connection-string keys, leaves SA_PASSWORD |

---

## Operations

### Toggle the load generator

The Helm chart includes a built-in `loadgen` that hammers the API to drive realistic traffic. Off by default to keep CloudWatch metrics readable.

```hcl
# main.tf — change "false" → "true"
set {
  name  = "loadgen.enabled"
  value = "true"
}
```

`terraform apply` and within ~90 seconds you'll see RDS metrics light up (DB Connections, Write IOPS, Network Receive Throughput).

### Edit the visual theme

The skin is a single CSS file living inside `kubernetes_config_map.skin`. Edit, `terraform apply`, and the Deployment automatically rolls because the ConfigMap hash is wired to a pod annotation:

```hcl
annotations = {
  "skin/config-hash" = sha256(kubernetes_config_map.skin.data["skin.css"])
}
```

To revert to the stock UI, point the Ingress backend back at `easytrade-frontendreverseproxy:8080`.

### Restart the DB-consuming services after a DB password rotation

```bash
kubectl rollout restart deployment -n easytrade \
  easytrade-broker-service easytrade-contentcreator \
  easytrade-credit-card-order-service easytrade-loginservice \
  easytrade-manager easytrade-pricing-service
```

(This is what `null_resource.restart_db_consumers` does on every connection-string change.)

### Rotate the RDS password manually

```bash
terraform taint random_password.easytrade_db
terraform apply
```

Terraform will regenerate the password, update the Secret, and roll the consumers automatically.

---

## Monitoring

| Where | What to look at |
|---|---|
| **RDS → easytrade-db → Monitoring** | Built-in 5-min CloudWatch graphs: DB Connections, IOPS, Throughput, CPU |
| **CloudWatch → AWS/RDS → DBInstanceIdentifier** | All metrics, custom timeranges, dashboardable |
| **CloudWatch → Logs → /aws/eks/easytrade-lab/cluster** | Control-plane audit logs |
| `kubectl get pods -n easytrade` | Pod health |
| `kubectl logs -n easytrade deploy/easytrade-manager` | Service-level errors (the Manager is the central orchestrator) |
| `kubectl get events -n easytrade --sort-by='.lastTimestamp'` | Recent cluster events |
| `kubectl top pods -n easytrade` | Resource usage (needs metrics-server, comes with the chart) |

To enable **Performance Insights** for query-level visibility (off by default to keep it free-tier-ish):

```hcl
performance_insights_enabled          = true
performance_insights_retention_period = 7   # 7 days = free
```

---

## Cost (us-east-1, rough)

| Component | Monthly |
|---|---:|
| EKS control plane | ~$73 |
| 1× t3.xlarge SPOT node | ~$36–45 |
| RDS db.t3.small SQL Server Express (license-included) | ~$32 |
| RDS storage 20 GB gp3 | ~$2.30 |
| ALB baseline | ~$16.50 |
| Cross-AZ DB traffic (~200 GB/mo with loadgen on) | ~$4 |
| **Total** | **~$165 / month** |

Excludes the existing VPC's NAT Gateway charges and per-public-IP fees.

To minimize cost during idle periods:

```bash
# Stop the RDS instance for up to 7 days at a time (~70% savings on instance hours)
aws rds stop-db-instance --db-instance-identifier easytrade-db

# Or scale the EKS node group to 0
aws eks update-nodegroup-config \
  --cluster-name easytrade-lab --nodegroup-name standard \
  --scaling-config minSize=0,maxSize=2,desiredSize=0
```

---

## Troubleshooting

<details>
<summary><b>Schema init Job fails with <code>BackoffLimitExceeded</code></b></summary>

Almost always a **CRLF in `main.tf`** leaking into the bash heredoc.

```bash
file main.tf                                    # → confirm "CRLF line terminators"
tr -d '\r' < main.tf > main.tf.tmp && mv main.tf.tmp main.tf
kubectl delete job init-rds-schema -n easytrade
terraform apply
```
</details>

<details>
<summary><b>Pods stuck in <code>ContainerCreating</code> after deploy</b></summary>

Usually image-pull from the Dynatrace registry; first pull is ~553 MB. Check:

```bash
kubectl describe pod <pod> -n easytrade | tail -30
```
</details>

<details>
<summary><b>RDS unreachable from a pod</b></summary>

Verify the Security Group allows port 1433 from the EKS node SG:

```bash
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=easytrade-db" \
  --query 'SecurityGroups[0].IpPermissions'
```

And that the RDS subnet group includes subnets the EKS nodes can route to.
</details>

<details>
<summary><b>Skin CSS not visible in the browser</b></summary>

The browser may have cached the un-skinned response. Hard reload (Cmd+Shift+R / Ctrl+Shift+R), and verify:

```bash
ALB=$(terraform output -raw alb_dns_name)
curl -s "http://$ALB/" | grep skin.css
# should print: <link rel="stylesheet" href="/__skin.css">
```
</details>

<details>
<summary><b><code>terraform apply</code> says "VPC not found"</b></summary>

You're targeting an account/region without the `np-lab` VPC. Edit `main.tf` lines 38–51 to point at your VPC ID and subnet tag pattern.
</details>

---

## Repo layout

```
.
├── main.tf                # All infra: EKS, addons, Helm release, ingress,
│                          #            RDS, schema-init Job, secret patch,
│                          #            skin proxy. ~430 lines.
├── README.md              # You are here.
├── LICENSE                # MIT — covers the Terraform code in this repo only.
├── .gitignore             # Excludes tfstate, tfvars, .terraform/, .claude/
└── .terraform.lock.hcl    # Provider version pins (committed for reproducibility)
```

---

## What was actually built (engineering deep dive)

EasyTrade ships as a Helm chart with an in-cluster MSSQL pod (`easytrade-db-0`) that all microservices share. That works as a demo, but it's not a realistic posture: the database lives and dies with the cluster, you can't see DB traffic on the network, and you can't observe it with real RDS tooling. This project takes that demo and rebuilds the data plane around managed AWS RDS, while keeping the chart unmodified.

Here's everything this stack does on top of a vanilla `helm install easytrade`, and why each choice was made:

### 1. Provisions an external RDS SQL Server Express

The chart's services (`manager`, `loginservice`, `broker-service`, `pricing-service`, `contentcreator`, `credit-card-order-service`) are compiled against MSSQL — they speak `sqlserver://` URLs and use the Microsoft JDBC / Go-mssqldb / .NET SqlClient drivers. **Postgres won't work**, even at the connection-string level. So we use `sqlserver-ex` (Express edition, license-included) on `db.t3.small`, which is the cheapest tier RDS allows for SQL Server.

### 2. Bootstraps the schema using the chart's own image

Rather than maintain a duplicate SQL dump that drifts on every chart bump, the init Job pulls `europe-docker.pkg.dev/.../easytrade/db:1.3.16` — the same image the in-cluster DB uses — and runs the bundled `/my-app/sql-*.sql` files (`create-database.sql`, `sql-accounts.sql`, `sql-trades.sql`, etc.) against the freshly-provisioned RDS. When EasyTrade is upgraded, the init scripts upgrade with it. We add an `EXISTS` check so re-runs are idempotent.

### 3. Atomically swaps the connection strings without fighting Helm

The Secret `easytrade-connection-strings` is owned by Helm. The naive approach — declaring a `kubernetes_secret` resource with the same name in Terraform — would fail because Helm already manages it. The right tool is **`kubernetes_secret_v1_data`**, which manages *only the keys you declare*, leaves all other keys (notably `SA_PASSWORD`, which the in-cluster DB pod still reads on boot) untouched, and never tries to take ownership of the resource. Helm's owner annotations stay intact. The in-cluster MSSQL pod keeps its bootstrap password and continues running idly; the application services use the new RDS credentials.

### 4. Rolls only the deployments that need to be rolled

After the Secret swap, only six of the chart's seventeen deployments actually consume `easytrade-connection-strings`. We restart exactly those — `manager`, `broker-service`, `contentcreator`, `credit-card-order-service`, `loginservice`, `pricing-service` — via a `null_resource` with a `kubectl rollout restart` provisioner. The frontend, the rabbitmq, the SPA, the reverse proxy, and the loadgen are never touched. End-user traffic to the ALB never goes 5xx.

### 5. AccountService doesn't open a JDBC connection at all

Inspect the AccountService JAR and you'll find **no `org.postgresql`, no `mssql-jdbc`, no Hibernate**. It uses `java.net.http.HttpClient` and reads a single `MANAGER_HOSTANDPORT` env var to forward calls to the Manager service. The `accountservice-db` Secret it consumes via `envFrom` is a vestigial relic of an earlier chart version. We keep it populated so the deployment can start, but its values never reach a database driver.

### 6. CSS injection without rebuilding any image

The custom theme has zero coupling to EasyTrade's source. No image rebuild, no JS bundle patch. An `nginx:1.27-alpine` Deployment (2 replicas) sits in front of `easytrade-frontendreverseproxy`, with `sub_filter` rewriting the `</head>` token in every `text/html` response to inject a `<link>` to `/__skin.css`. Because the CSS uses element-level selectors (`button`, `input`, `table`) plus `!important`, it overrides the SPA's compiled styles regardless of which framework generated them. The Ingress backend points at the skin Service; everything else proxies through transparently. To revert to the stock UI, change the Ingress backend back to `easytrade-frontendreverseproxy:8080` and `terraform apply`.

### 7. Single file, no modules

Everything lives in **one `main.tf`**. No modules, no remote state, no glue scripts, no `for_each` over imaginary environments. Read it top to bottom and you'll know exactly what the cluster looks like. When something breaks, there's exactly one file to grep.

---

## License & Attributions

**TradeStorm is open source software.** The Terraform code in this repository (`main.tf` and supporting files) is released under the **MIT License** — see [LICENSE](LICENSE). You may use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the code, including for commercial purposes. The only requirement is that the copyright notice and license text remain included in copies or substantial portions of the software.

The MIT grant covers only the IaC authored here. It does **not** extend to anything pulled in at deploy time:

| Component | Owner / License | How it's used here |
|---|---|---|
| **EasyTrade** application & Helm chart | © Dynatrace LLC | Pulled at deploy time from `oci://europe-docker.pkg.dev/dynatrace-demoability/helm`. Not redistributed by this repository. |
| **SQL Server 2022 Express** | © Microsoft Corporation | Provisioned via AWS RDS license-included. Not redistributed by this repository. |
| **AWS Load Balancer Controller, EKS Blueprints Addons, kube-proxy, etc.** | Apache 2.0 / MIT (community / AWS) | Installed at deploy time as Helm charts and container images from upstream registries. Not redistributed by this repository. |

If you fork this repo, the MIT License covers only the Terraform code. You remain responsible for complying with each upstream license for anything this stack deploys on your behalf.

This project is **not affiliated with Dynatrace, Microsoft, or AWS**. EasyTrade is a publicly available demo application provided by Dynatrace; this repository simply automates a particular AWS deployment of it.
