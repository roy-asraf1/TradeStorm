# --- 1. Providers ---
terraform {
  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.0" }
    helm       = { source = "hashicorp/helm", version = "~> 2.0" }
    random     = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# --- 2. Network Data (VPC np-lab) ---
data "aws_vpc" "existing" {
  id = "vpc-01ef4e3d50795d273"
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.id]
  }
  filter {
    name   = "tag:Name"
    values = ["np-lab-Private-*"]
  }
}

# --- Data Source שמוצא אוטומטית את הגרסה הכי חדשה של kube-proxy ---
data "aws_eks_addon_version" "latest_kube_proxy" {
  addon_name         = "kube-proxy"
  kubernetes_version = "1.34" # הגרסה של הקלאסטר שלך
  most_recent        = true
}

# --- 3. EKS Cluster (מעודכן עם התיקון הכללי) ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "easytrade-lab"
  cluster_version = "1.34" # הגרסה שראינו ב-Error



  vpc_id     = data.aws_vpc.existing.id
  subnet_ids = data.aws_subnets.private.ids

  cluster_endpoint_public_access = true
  enable_irsa                    = true

  # כאן נכנס התיקון הכללי
  cluster_addons = {
    kube-proxy = {
      # כאן אנחנו משתמשים במידע מה-Data Source למעלה במקום בטקסט קבוע
      addon_version               = data.aws_eks_addon_version.latest_kube_proxy.version
      resolve_conflicts_on_update = "PRESERVE"
    }
  }

  eks_managed_node_groups = {
    standard = {
      instance_types = ["t3.xlarge"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
      capacity_type  = "SPOT"


    }
  }
}

# --- 4. AWS Load Balancer Controller ---
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_aws_load_balancer_controller = true
}

# --- 5. EasyTrade Application ---
resource "helm_release" "easytrade" {
  name             = "easytrade"
  repository       = "oci://europe-docker.pkg.dev/dynatrace-demoability/helm"
  chart            = "easytrade"
  namespace        = "easytrade"
  create_namespace = true
  wait             = false

  # הגדרות משאבים - מבטיח ש-Limit תמיד גבוה מ-Request
  set {
    name  = "frontend.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "frontend.resources.requests.memory"
    value = "128Mi"
  }
  set {
    name  = "frontend.resources.limits.cpu"
    value = "300m"
  }
  set {
    name  = "frontend.resources.limits.memory"
    value = "256Mi"
  }

  set {
    name  = "frontendreverseproxy.service.type"
    value = "ClusterIP"
  }
  set {
    name  = "frontendreverseproxy.replicaCount"
    value = "2"
  }
  # כיבוי ה-Load Generator הפנימי
  set {
    name  = "loadgen.enabled"
    value = "false"
  }
}


# --- 6. Explicit Ingress (זה מה שיקים את ה-ALB בטוח) ---
resource "kubernetes_ingress_v1" "easytrade_ingress" {
  metadata {
    name      = "easytrade-ingress"
    namespace = "easytrade"
    annotations = {
      # הגדרות בסיסיות ל-ALB
      "kubernetes.io/ingress.class"           = "alb"
      "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
      "alb.ingress.kubernetes.io/target-type" = "ip"

      # הגדרות Health Check - לפי הבדיקה שעשינו ב-curl
      "alb.ingress.kubernetes.io/healthcheck-path" = "/api/Login"
      "alb.ingress.kubernetes.io/success-codes"    = "200"

      # אופציונלי: הגדרת פורטים (למקרה שה-Controller דורש הצהרה מפורשת)
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 80}]"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              # ALB → skin proxy (nginx) → easytrade-frontendreverseproxy → ...
              name = "easytrade-skin"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  # כאן ה-depends_on יושב נכון (בתוך ה-Resource אבל מחוץ ל-Metadata)
  # וודא שהשמות כאן תואמים למשאבים האמיתיים שלך ב-Terraform
  depends_on = [
    # דוגמה: module.eks_blueprints_addons (או שם ה-addon של ה-ALB controller)
    # דוגמה: aws_eks_node_group.main
  ]
}

# --- 7. RDS SQL Server Express (replaces in-cluster easytrade-db so DB traffic flows over the network) ---

resource "aws_db_subnet_group" "easytrade" {
  name       = "easytrade-db"
  subnet_ids = data.aws_subnets.private.ids
}

resource "aws_security_group" "easytrade_db" {
  name   = "easytrade-db"
  vpc_id = data.aws_vpc.existing.id

  ingress {
    from_port       = 1433
    to_port         = 1433
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "random_password" "easytrade_db" {
  length      = 20
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

resource "aws_db_instance" "easytrade" {
  identifier     = "easytrade-db"
  engine         = "sqlserver-ex"
  engine_version = "16.00.4245.2.v1"
  instance_class = "db.t3.small"

  allocated_storage = 20
  storage_type      = "gp3"

  username = "easytradeadmin"
  password = random_password.easytrade_db.result

  license_model = "license-included"

  db_subnet_group_name   = aws_db_subnet_group.easytrade.name
  vpc_security_group_ids = [aws_security_group.easytrade_db.id]
  publicly_accessible    = false

  port = 1433

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

# Keep the chart's accountservice-db secret populated so the AccountService pod (envFrom) can start.
# AccountService doesn't actually open a JDBC connection - it talks to Manager over HTTP - so the
# values here are unused; we point them at RDS for consistency.
resource "kubernetes_secret" "accountservice_db" {
  metadata {
    name      = "accountservice-db"
    namespace = "easytrade"
  }

  data = {
    host     = aws_db_instance.easytrade.address
    port     = tostring(aws_db_instance.easytrade.port)
    database = "TradeManagement"
    username = aws_db_instance.easytrade.username
    password = random_password.easytrade_db.result
  }

  depends_on = [helm_release.easytrade]
}

# Run the easytrade db image as a one-shot Job so its built-in SQL init scripts
# (create-database.sql + sql-*.sql) run against RDS instead of localhost.
resource "kubernetes_job_v1" "init_rds_schema" {
  metadata {
    name      = "init-rds-schema"
    namespace = "easytrade"
  }

  spec {
    backoff_limit              = 1
    ttl_seconds_after_finished = 3600

    template {
      metadata {
        labels = { app = "init-rds-schema" }
      }

      spec {
        restart_policy = "Never"

        container {
          name              = "init"
          image             = "europe-docker.pkg.dev/dynatrace-demoability/docker/easytrade/db:1.3.16"
          image_pull_policy = "IfNotPresent"
          command           = ["/bin/bash", "-c"]
          args = [<<-EOT
            set -eo pipefail
            cd /my-app

            echo "Waiting for RDS to accept connections..."
            for i in $(seq 1 60); do
              if /opt/mssql-tools/bin/sqlcmd -S "$RDS_HOST,1433" -U "$RDS_USER" -P "$RDS_PASS" -l 10 -Q "SELECT 1" >/dev/null 2>&1; then
                echo "RDS reachable."
                break
              fi
              echo "  not ready, retrying ($i/60)..."
              sleep 10
            done

            echo "Checking if TradeManagement already exists on RDS..."
            EXISTS=$(/opt/mssql-tools/bin/sqlcmd -S "$RDS_HOST,1433" -U "$RDS_USER" -P "$RDS_PASS" -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name='TradeManagement'" | tr -d '[:space:]')
            if [ "$EXISTS" = "1" ]; then
              echo "TradeManagement already initialized on RDS - skipping."
              exit 0
            fi

            echo "Creating TradeManagement..."
            /opt/mssql-tools/bin/sqlcmd -S "$RDS_HOST,1433" -U "$RDS_USER" -P "$RDS_PASS" -d master -i create-database.sql

            echo "Loading schema + seed data..."
            for f in sql-packages.sql sql-accounts.sql sql-balance.sql sql-products.sql sql-instruments.sql sql-pricing.sql sql-ownedinstruments.sql sql-trades.sql sql-balancehistory.sql sql-creditcardorders.sql sql-creditcardorderstatus.sql sql-creditcards.sql; do
              echo "  applying $f"
              /opt/mssql-tools/bin/sqlcmd -S "$RDS_HOST,1433" -U "$RDS_USER" -P "$RDS_PASS" -d master -i "$f"
            done

            echo "RDS schema initialization complete."
          EOT
          ]

          env {
            name  = "RDS_HOST"
            value = aws_db_instance.easytrade.address
          }
          env {
            name  = "RDS_USER"
            value = aws_db_instance.easytrade.username
          }
          env {
            name  = "RDS_PASS"
            value = random_password.easytrade_db.result
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "30m"
    update = "30m"
  }

  depends_on = [
    aws_db_instance.easytrade,
    helm_release.easytrade,
  ]
}

# Override only the connection strings inside the Helm-managed secret.
# SA_PASSWORD is intentionally left untouched so the in-cluster easytrade-db pod
# (which uses it to bootstrap MSSQL) keeps working - it will simply sit idle.
resource "kubernetes_secret_v1_data" "connection_strings_to_rds" {
  metadata {
    name      = "easytrade-connection-strings"
    namespace = "easytrade"
  }

  data = {
    DOTNET_CONNECTION_STRING = "Data Source=${aws_db_instance.easytrade.address},1433;Initial Catalog=TradeManagement;Persist Security Info=True;User ID=${aws_db_instance.easytrade.username};Password=${random_password.easytrade_db.result};TrustServerCertificate=true"
    GO_CONNECTION_STRING     = "sqlserver://${aws_db_instance.easytrade.username}:${random_password.easytrade_db.result}@${aws_db_instance.easytrade.address}:1433?database=TradeManagement&connection+encrypt=false&connection+TrustServerCertificate=false&connection+loginTimeout=30"
    JAVA_CONNECTION_STRING   = "jdbc:sqlserver://${aws_db_instance.easytrade.address}:1433;database=TradeManagement;user=${aws_db_instance.easytrade.username};password=${random_password.easytrade_db.result};encrypt=false;trustServerCertificate=false;loginTimeout=30;"
  }

  field_manager = "terraform"
  force         = true

  depends_on = [kubernetes_job_v1.init_rds_schema]
}

# Roll the deployments that consume the connection strings so they pick up RDS.
resource "null_resource" "restart_db_consumers" {
  triggers = {
    secret_revision = kubernetes_secret_v1_data.connection_strings_to_rds.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl rollout restart deployment -n easytrade \
        easytrade-broker-service \
        easytrade-contentcreator \
        easytrade-credit-card-order-service \
        easytrade-loginservice \
        easytrade-manager \
        easytrade-pricing-service
    EOT
  }
}

# --- 7.5 Skin proxy: nginx that wraps frontendreverseproxy and injects custom CSS ---
# Result: ALB --> nginx-skin (CSS injection) --> easytrade-frontendreverseproxy --> services

resource "kubernetes_config_map" "skin" {
  metadata {
    name      = "easytrade-skin"
    namespace = "easytrade"
  }

  data = {
    "nginx.conf" = <<-NGINX
      worker_processes 1;
      events { worker_connections 1024; }
      http {
        include       /etc/nginx/mime.types;
        default_type  application/octet-stream;
        sendfile      on;
        keepalive_timeout 65;

        server {
          listen 80;
          server_name _;

          # Serve our custom stylesheet
          location = /__skin.css {
            alias /skin/skin.css;
            add_header Cache-Control "public, max-age=300";
            default_type text/css;
          }

          # Everything else: proxy to the real reverse proxy and inject the stylesheet
          location / {
            proxy_pass http://easytrade-frontendreverseproxy.easytrade.svc.cluster.local:8080;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            # Force uncompressed responses so sub_filter can rewrite them
            proxy_set_header Accept-Encoding "";

            sub_filter_once off;
            sub_filter_types text/html;
            sub_filter '</head>' '<link rel="stylesheet" href="/__skin.css"></head>';
          }
        }
      }
    NGINX

    "skin.css" = <<-CSS
      /* ===========================================================
         EASYTRADE PARTY MODE - skin overlay
         =========================================================== */

      :root {
        --skin-pink:    #ff006e;
        --skin-purple:  #8338ec;
        --skin-cyan:    #00f5ff;
        --skin-yellow:  #ffbe0b;
        --skin-orange:  #fb5607;
        --skin-mint:    #06ffa5;
      }

      @keyframes skin-rainbow {
        0%   { background-position:   0% 50%; }
        50%  { background-position: 100% 50%; }
        100% { background-position:   0% 50%; }
      }

      @keyframes skin-float {
        0%, 100% { transform: translateY(0); }
        50%      { transform: translateY(-8px); }
      }

      @keyframes skin-glow {
        0%, 100% { box-shadow: 0 0 20px var(--skin-pink),  0 0 40px rgba(255,0,110,0.4); }
        50%      { box-shadow: 0 0 25px var(--skin-cyan),  0 0 50px rgba(0,245,255,0.4); }
      }

      @keyframes skin-wiggle {
        0%, 100% { transform: rotate(-1deg); }
        50%      { transform: rotate( 1deg); }
      }

      /* ---------- Page-wide ---------- */
      html, body {
        background: linear-gradient(135deg,
          #ff006e 0%, #8338ec 25%, #00f5ff 50%, #ffbe0b 75%, #fb5607 100%) !important;
        background-size: 400% 400% !important;
        animation: skin-rainbow 18s ease infinite !important;
        color: #1a1a2e !important;
        font-family: 'Comic Sans MS', 'Marker Felt', 'Chalkboard SE', cursive !important;
      }

      * {
        font-family: 'Comic Sans MS', 'Marker Felt', cursive !important;
      }

      /* Floating emoji confetti background */
      body::before {
        content: '';
        position: fixed; inset: 0;
        pointer-events: none;
        z-index: 0;
        background-image:
          url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='80' height='80'><text y='50' font-size='40'>🎉</text></svg>"),
          url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='80' height='80'><text y='50' font-size='40'>💸</text></svg>"),
          url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='80' height='80'><text y='50' font-size='40'>📈</text></svg>"),
          url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='80' height='80'><text y='50' font-size='40'>🚀</text></svg>");
        background-size: 200px 200px;
        background-position: 0 0, 100px 100px, 50px 50px, 150px 150px;
        opacity: 0.10;
      }

      /* Top "PARTY MODE" banner */
      body::after {
        content: '🎉  EASYTRADE  PARTY  MODE  🎉  💰  💸  📈  🚀  🎊  ' attr(data-spacer);
        position: fixed; top: 0; left: 0; right: 0;
        z-index: 9999;
        background: linear-gradient(90deg, var(--skin-pink), var(--skin-purple), var(--skin-cyan), var(--skin-yellow), var(--skin-pink));
        background-size: 300% 100%;
        animation: skin-rainbow 8s linear infinite;
        color: white !important;
        font-weight: 900 !important;
        font-size: 16px !important;
        letter-spacing: 4px !important;
        padding: 8px 0 !important;
        text-align: center !important;
        text-shadow: 2px 2px 0 rgba(0,0,0,0.3) !important;
        pointer-events: none;
        text-transform: uppercase;
      }

      /* Push real content below the banner */
      body > * {
        position: relative;
        z-index: 1;
        padding-top: 0;
      }
      body > *:first-child {
        margin-top: 40px !important;
      }

      /* ---------- Headings ---------- */
      h1, h2, h3, h4, h5, h6 {
        color: white !important;
        text-shadow:
          3px 3px 0 var(--skin-pink),
          6px 6px 0 var(--skin-purple),
          9px 9px 12px rgba(0,0,0,0.3) !important;
        animation: skin-float 3s ease-in-out infinite !important;
        font-weight: 900 !important;
        letter-spacing: 2px !important;
      }
      h1::before { content: '🎉 '; }
      h2::before { content: '✨ '; }
      h3::before { content: '🔥 '; }

      /* ---------- Buttons ---------- */
      button,
      input[type="button"],
      input[type="submit"],
      a.btn, .btn, [class*="btn-"], [role="button"] {
        background: linear-gradient(45deg, var(--skin-pink), var(--skin-purple)) !important;
        color: white !important;
        border: 3px solid white !important;
        border-radius: 50px !important;
        padding: 12px 28px !important;
        font-weight: 900 !important;
        text-transform: uppercase !important;
        letter-spacing: 2px !important;
        cursor: pointer !important;
        transition: transform 0.2s ease, box-shadow 0.2s ease !important;
        animation: skin-glow 3s ease-in-out infinite !important;
        text-decoration: none !important;
        display: inline-block;
      }
      button:hover,
      input[type="button"]:hover,
      input[type="submit"]:hover,
      a.btn:hover, .btn:hover {
        transform: scale(1.08) rotate(-2deg) !important;
        background: linear-gradient(45deg, var(--skin-cyan), var(--skin-mint)) !important;
        color: #1a1a2e !important;
      }
      button::after,
      input[type="submit"]::after { content: ' 🚀'; }

      /* ---------- Inputs ---------- */
      input[type="text"],
      input[type="password"],
      input[type="email"],
      input[type="number"],
      input[type="search"],
      select, textarea {
        background: rgba(255,255,255,0.96) !important;
        border: 3px solid var(--skin-purple) !important;
        border-radius: 18px !important;
        padding: 10px 16px !important;
        color: #1a1a2e !important;
        font-weight: bold !important;
        outline: none !important;
        transition: border-color 0.2s ease, box-shadow 0.2s ease !important;
      }
      input:focus, select:focus, textarea:focus {
        border-color: var(--skin-pink) !important;
        box-shadow: 0 0 0 4px rgba(255,0,110,0.3) !important;
      }

      /* ---------- Containers / cards / panels ---------- */
      .card, [class*="card"],
      .panel, [class*="panel"],
      [class*="container"],
      [class*="box"],
      [class*="tile"],
      [class*="widget"] {
        background: rgba(255,255,255,0.96) !important;
        color: #1a1a2e !important;
        border: 3px solid white !important;
        border-radius: 25px !important;
        box-shadow: 0 10px 40px rgba(0,0,0,0.25) !important;
        padding: 20px !important;
      }

      /* ---------- Tables ---------- */
      table {
        background: rgba(255,255,255,0.95) !important;
        border-radius: 20px !important;
        overflow: hidden !important;
        border-spacing: 0 !important;
        border-collapse: separate !important;
        box-shadow: 0 8px 30px rgba(0,0,0,0.2) !important;
      }
      thead th, th {
        background: linear-gradient(45deg, var(--skin-pink), var(--skin-purple)) !important;
        color: white !important;
        font-weight: 900 !important;
        text-transform: uppercase;
        letter-spacing: 1.5px;
        padding: 14px !important;
      }
      tbody tr:nth-child(odd)  { background: rgba(131, 56, 236, 0.08) !important; }
      tbody tr:nth-child(even) { background: rgba(255, 0, 110, 0.06) !important; }
      tbody tr:hover { background: rgba(255, 190, 11, 0.25) !important; }
      td { padding: 12px !important; color: #1a1a2e !important; }

      /* ---------- Links ---------- */
      a {
        color: var(--skin-yellow) !important;
        font-weight: bold !important;
        text-decoration: none !important;
        transition: color 0.2s ease;
      }
      a:hover {
        color: var(--skin-cyan) !important;
        text-decoration: underline wavy !important;
      }

      /* ---------- Navbar / header / footer ---------- */
      nav, header, footer,
      [class*="navbar"], [class*="header"], [class*="footer"], [class*="nav-"] {
        background: rgba(26,26,46,0.85) !important;
        color: white !important;
        backdrop-filter: blur(10px) !important;
        border: 2px solid rgba(255,255,255,0.2) !important;
        border-radius: 18px !important;
        padding: 12px !important;
        animation: skin-wiggle 6s ease-in-out infinite !important;
      }
      nav *, header *, footer * { color: white !important; }

      /* ---------- Misc text bling ---------- */
      label, span, p, li, td {
        color: inherit;
      }
      strong, b {
        color: var(--skin-pink) !important;
      }

      /* Scrollbar 🎀 */
      ::-webkit-scrollbar { width: 14px; height: 14px; }
      ::-webkit-scrollbar-track {
        background: rgba(0,0,0,0.1);
      }
      ::-webkit-scrollbar-thumb {
        background: linear-gradient(180deg, var(--skin-pink), var(--skin-purple));
        border-radius: 10px;
        border: 3px solid rgba(255,255,255,0.6);
      }
      ::-webkit-scrollbar-thumb:hover {
        background: linear-gradient(180deg, var(--skin-cyan), var(--skin-mint));
      }
    CSS
  }
}

resource "kubernetes_deployment_v1" "skin" {
  metadata {
    name      = "easytrade-skin"
    namespace = "easytrade"
    labels    = { app = "easytrade-skin" }
  }

  spec {
    replicas = 2
    selector {
      match_labels = { app = "easytrade-skin" }
    }
    template {
      metadata {
        labels      = { app = "easytrade-skin" }
        annotations = {
          # Bump this to force a rollout when the configmap changes.
          "skin/config-hash" = sha256(kubernetes_config_map.skin.data["skin.css"])
        }
      }
      spec {
        container {
          name              = "nginx"
          image             = "nginx:1.27-alpine"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 80
            name           = "http"
          }

          resources {
            requests = { cpu = "30m",  memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }

          volume_mount {
            name       = "nginx-config"
            mount_path = "/etc/nginx/nginx.conf"
            sub_path   = "nginx.conf"
            read_only  = true
          }
          volume_mount {
            name       = "skin-css"
            mount_path = "/skin"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/__skin.css"
              port = "http"
            }
            period_seconds = 5
          }
        }

        volume {
          name = "nginx-config"
          config_map {
            name  = kubernetes_config_map.skin.metadata[0].name
            items {
              key  = "nginx.conf"
              path = "nginx.conf"
            }
          }
        }
        volume {
          name = "skin-css"
          config_map {
            name = kubernetes_config_map.skin.metadata[0].name
            items {
              key  = "skin.css"
              path = "skin.css"
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.easytrade]
}

resource "kubernetes_service_v1" "skin" {
  metadata {
    name      = "easytrade-skin"
    namespace = "easytrade"
  }
  spec {
    selector = { app = "easytrade-skin" }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# --- 8. Outputs ---
output "alb_dns_name" {
  value = kubernetes_ingress_v1.easytrade_ingress.status[0].load_balancer[0].ingress[0].hostname
}

output "alb_check_command" {
  value = "kubectl get ingress -n easytrade"
}

output "easytrade_db_endpoint" {
  value = aws_db_instance.easytrade.address
}