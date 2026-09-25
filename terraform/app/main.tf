module "vpc" {
  source = "../modules/vpc"

  azs = var.azs

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"    = "1"
    "kubernetes.io/cluster/main-cluster" = "shared"
  }
}

module "rds_sg" {
  source = "../modules/sg"

  name   = "rds-sg"
  vpc_id = module.vpc.vpc_id

  ingress_rules = [
    {
      from_port                = 5432 # Port PostgreSQL
      to_port                  = 5432 # Port PostgreSQL
      protocol                 = "tcp"
      source_security_group_id = module.eks.node_security_group_id
      description              = "Allow DB access from EKS nodes"
    }
  ]
}

resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = module.vpc.db_subnets

  tags = {
    Name = "RDS Subnet Group"
  }
}

module "rds" {
  source = "../modules/rds"

  db_identifier             = "main-db"
  db_name                   = "odoo"
  db_username               = "odoo"
  db_password               = random_password.odoo_db.result # Généré et stocké dans Secrets Manager, voir external-secrets.tf.
  db_engine_version         = "16.15"                        # Dernière version disponible au 2026-09-23 (vérifié via `aws rds describe-db-engine-versions`).
  db_subnet_group_name      = aws_db_subnet_group.rds_subnet_group.name
  db_vpc_security_group_ids = [module.rds_sg.security_group_id]
}

module "eks" {
  source = "../modules/eks"

  cluster_name       = "main-cluster"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets


  access_entries = {
    mon_acces_perso = {
      principal_arn = "arn:aws:iam::169332976667:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_PowerUserAccess_41a1a8fb17b69510"

      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    cicd_runner = {
      principal_arn = var.cicd_iam_role_arn
      user_name     = "cicd-runner"

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }
}

module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name_prefix = "ebs-csi-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = {
    Name = "iam-role-ebs-csi"
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = null
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn

  depends_on = [
    module.eks,
    module.ebs_csi_irsa_role
  ]
}

resource "kubernetes_namespace_v1" "app_namespace" {
  metadata {
    name = "ic-webapp"
  }
}

resource "kubernetes_config_map_v1" "odoo_config" {
  metadata {
    name      = "odoo-config"
    namespace = "ic-webapp"
  }
  depends_on = [
    kubernetes_namespace_v1.app_namespace
  ]
  data = {
    HOST = module.rds.db_instance_address # Récupération dynamique de l'adresse RDS
    USER = module.rds.db_username         # Récupération dynamique de l'utilisateur
  }
}

# Hosted zone créée et maintenue par terraform/bootstrap (NS stables, délégation
# chez le registrar à faire une seule fois) et certificat ACM du domaine,
# utilisés par le contrôleur ALB (module.eks) et par ExternalDNS.
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

module "ssl_certificate" {
  source = "../modules/certificate"

  domain_name = var.domain_name
  zone_id     = data.aws_route53_zone.main.zone_id
  environment = var.environment
}

# Supervision du cluster : métriques (AMP), logs applicatifs (CloudWatch),
# visualisation (AMG). Détail complet et justifications dans le module,
# voir modules/observability/main.tf.
module "observability" {
  source = "../modules/observability"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  aws_region        = var.aws_region
  environment       = var.environment
  admin_user_email  = var.admin_user_email

  # Le chart kube-prometheus-stack et aws-for-fluent-bit créent aussi des
  # Service (webhook du prometheus-operator, kube-state-metrics...) : même
  # précaution que pour les autres composants face au webhook du contrôleur
  # ALB pas encore prêt (voir alb-controller.tf).
  depends_on = [module.eks, helm_release.aws_load_balancer_controller]
}

