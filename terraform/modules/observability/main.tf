# Supervision du cluster EKS : métriques (Amazon Managed Prometheus, relayées
# par Prometheus en mode "forward only", sans stockage persistant), logs
# applicatifs (CloudWatch Logs, via Fluent Bit) et visualisation (Amazon
# Managed Grafana, connectée aux deux). Fluent Bit et Prometheus restent deux
# agents séparés plutôt qu'un collecteur unique (ADOT) : chaque outil reste
# dans son domaine, une panne de l'un n'affecte pas l'autre, et les deux
# bénéficient d'une configuration bien plus documentée pour ce cas d'usage
# précis (remote_write SigV4 vers AMP, sortie CloudWatch).

# ─────────────────────────────────────────────────────────────────────────
# Amazon Managed Prometheus (AMP)
# ─────────────────────────────────────────────────────────────────────────

resource "aws_prometheus_workspace" "main" {
  alias = var.cluster_name

  tags = {
    Name        = "${var.cluster_name}-amp"
    Environment = var.environment
  }
}

module "prometheus_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name_prefix = "prometheus-"
  # Aucune policy prédéfinie du module ne couvre AMP : policy personnalisée
  # ci-dessous, attachée séparément (aws_iam_role_policy).

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.monitoring_namespace}:kube-prometheus-stack-prometheus"]
    }
  }

  tags = {
    Name = "iam-role-prometheus"
  }
}

# Écriture seule vers AMP, scopée à ce workspace précis : Prometheus n'a
# jamais besoin de lire (ni de créer/supprimer) le workspace lui-même.
resource "aws_iam_role_policy" "prometheus_remote_write" {
  name = "amp-remote-write"
  role = module.prometheus_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["aps:RemoteWrite"]
        Resource = aws_prometheus_workspace.main.arn
      }
    ]
  })
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.prometheus_chart_version
  namespace        = var.monitoring_namespace
  create_namespace = true
  atomic           = true
  cleanup_on_fail  = true
  depends_on       = [module.prometheus_irsa]

  values = [
    yamlencode({
      # Pas de Grafana ni d'Alertmanager auto-hébergés : remplacés par
      # Amazon Managed Grafana ci-dessous.
      grafana = {
        enabled = false
      }
      alertmanager = {
        enabled = false
      }
      prometheus = {
        serviceAccount = {
          create = true
          name   = "kube-prometheus-stack-prometheus"
          annotations = {
            "eks.amazonaws.com/role-arn" = module.prometheus_irsa.iam_role_arn
          }
        }
        prometheusSpec = {
          # Rétention locale courte : simple tampon, la donnée durable vit
          # dans AMP via remoteWrite. Pas de storageSpec -> pas de volume
          # persistant.
          retention = "6h"
          remoteWrite = [
            {
              url = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
              sigv4 = {
                region = var.aws_region
              }
            }
          ]
        }
      }
    })
  ]
}

# ─────────────────────────────────────────────────────────────────────────
# Logs applicatifs : Fluent Bit -> CloudWatch Logs
# ─────────────────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "application_logs" {
  name              = "/eks/${var.cluster_name}/application"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "${var.cluster_name}-application-logs"
    Environment = var.environment
  }
}

module "fluent_bit_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name_prefix = "fluent-bit-"

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.monitoring_namespace}:aws-for-fluent-bit"]
    }
  }

  tags = {
    Name = "iam-role-fluent-bit"
  }
}

resource "aws_iam_role_policy" "fluent_bit_cloudwatch" {
  name = "cloudwatch-logs-write"
  role = module.fluent_bit_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
        ]
        Resource = [
          aws_cloudwatch_log_group.application_logs.arn,
          "${aws_cloudwatch_log_group.application_logs.arn}:*",
        ]
      }
    ]
  })
}

resource "helm_release" "aws_for_fluent_bit" {
  name             = "aws-for-fluent-bit"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-for-fluent-bit"
  version          = var.fluent_bit_chart_version
  namespace        = var.monitoring_namespace
  create_namespace = true
  atomic           = true
  cleanup_on_fail  = true
  depends_on       = [module.fluent_bit_irsa]

  values = [
    yamlencode({
      serviceAccount = {
        create = true
        name   = "aws-for-fluent-bit"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.fluent_bit_irsa.iam_role_arn
        }
      }
      cloudWatch = {
        enabled = true
        region  = var.aws_region
        # Le groupe est déjà créé par Terraform ci-dessus.
        logGroupName = aws_cloudwatch_log_group.application_logs.name
        # Un flux de log par pod, préfixé pour les distinguer : le plugin
        # CloudWatch refuse une chaîne vide ("log_stream_name or
        # log_stream_prefix is required", constaté à l'apply).
        logStreamPrefix = "fluentbit-"
        autoCreateGroup = false
      }
      # Le chart embarque deux plugins CloudWatch distincts : "cloudWatch"
      # (configuré ci-dessus) et "cloudWatchLogs", activé par défaut
      # (enabled: true) et pointant vers son propre log group par défaut
      # (/aws/eks/fluentbit-cloudwatch/logs, hors du scope IAM du rôle
      # fluent-bit) si on ne le désactive pas explicitement — constaté à
      # l'apply (AccessDeniedException sur ce second groupe).
      cloudWatchLogs = {
        enabled = false
      }
      # Les autres sorties du chart (Kinesis, ES, S3) ne sont pas utilisées.
      elasticsearch = {
        enabled = false
      }
      kinesis = {
        enabled = false
      }
      firehose = {
        enabled = false
      }
    })
  ]
}

# ─────────────────────────────────────────────────────────────────────────
# Amazon Managed Grafana (AMG)
# ─────────────────────────────────────────────────────────────────────────
# Étapes manuelles restantes après l'apply, non automatisées :
# 1. Associer un administrateur au workspace (IAM Identity Center → Grafana
#    → "Assign new user or group in Identity Center"). Volontairement HORS
#    Terraform : gérer ça via aws_grafana_role_association exige, côté rôle
#    CI, des policies larges et privilégiées au niveau du compte entier
#    (AWSSSODirectoryAdministrator, AWSSSOMasterAccountAdministrator,
#    documentées par AWS) — un accès admin sur tout IAM Identity Center,
#    disproportionné pour automatiser une association qui ne change jamais
#    après sa création. Constaté à l'usage : même en ajoutant action par
#    action ce que demandait chaque erreur (grafana:ListPermissions...), le
#    service échoue quand même ("Unable to list users from managed
#    application") tant que ces policies larges ne sont pas accordées.
# 2. Ajouter, dans l'UI Grafana, les sources de données Prometheus (endpoint
#    = aws_prometheus_workspace.main) et CloudWatch (région + log group).
#    Non automatisable ici sans le provider Terraform "grafana" séparé
#    (authentification propre à l'API Grafana, hors scope). "data_sources"
#    ci-dessous ne fait qu'autoriser le rôle IAM à lire ces services AWS ;
#    il ne crée pas la connexion dans Grafana lui-même.

# Rôle assumé par le service Grafana (pas par un pod du cluster : AMG est un
# service managé, hors EKS) pour lire AMP et CloudWatch en son nom.
resource "aws_iam_role" "grafana" {
  name = "grafana-workspace-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "grafana.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "iam-role-grafana-workspace"
    Environment = var.environment
  }
}

resource "aws_grafana_workspace" "main" {
  name                     = var.cluster_name
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  # SERVICE_MANAGED est censé attacher automatiquement, sur aws_iam_role.
  # grafana, une policy couvrant les data_sources listés ci-dessous — en
  # pratique, bug connu du provider Terraform (aucune policy réellement
  # attachée, constaté à l'usage : 403 sur les requêtes Prometheus, rôle
  # sans aucune policy attachée en le vérifiant directement). On attache donc
  # nous-mêmes, ci-dessous, les policies managées AWS équivalentes
  # (AmazonPrometheusQueryAccess, AmazonGrafanaCloudWatchAccess), pas scopées
  # à CE workspace précis (comme le sont nos rôles IRSA écrits à la main),
  # mais fiables — un compromis documenté plutôt qu'un mécanisme cassé.
  permission_type = "SERVICE_MANAGED"
  role_arn        = aws_iam_role.grafana.arn
  data_sources    = ["CLOUDWATCH", "PROMETHEUS"]

  tags = {
    Name        = "${var.cluster_name}-amg"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "grafana_prometheus" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess"
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonGrafanaCloudWatchAccess"
}
