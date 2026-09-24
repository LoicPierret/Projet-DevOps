# External Secrets Operator (ESO) : synchronise dans le cluster, sous forme
# de Secret Kubernetes, des secrets détenus par AWS Secrets Manager. Les
# ExternalSecret consommant ce ClusterSecretStore vivent dans le dépôt GitOps
# (apps/odoo, apps/pgadmin), pas ici : Terraform ne fait que poser la
# connexion (IRSA + ClusterSecretStore), pas les secrets applicatifs.

# Clé KMS par défaut d'AWS pour Secrets Manager (utilisée par les deux
# secrets ci-dessous, aucun ne précise de clé dédiée). Sert à scoper
# précisément le droit kms:Decrypt d'ESO plutôt que d'ouvrir sur toutes les
# clés du compte.
data "aws_kms_alias" "secretsmanager" {
  name = "alias/aws/secretsmanager"
}

# Mot de passe pgAdmin : contrairement à RDS, ce service n'a pas de mécanisme
# natif de mot de passe géré par AWS. Terraform en génère un et le stocke
# dans Secrets Manager ; External Secrets Operator le recopie ensuite dans un
# Secret Kubernetes.
resource "random_password" "pgadmin" {
  length  = 24
  special = true
  # Évite les caractères pouvant poser problème dans une valeur passée en
  # variable d'environnement Docker/Kubernetes.
  override_special = "!#%&*+-=?^_"
}

resource "aws_secretsmanager_secret" "pgadmin" {
  name                    = "pgadmin-admin-password"
  description             = "Mot de passe admin pgAdmin, consommé par External Secrets Operator (apps/pgadmin)."
  recovery_window_in_days = 0 # Pas de fenêtre de récupération : évite un conflit de nom si le secret est recréé rapidement (démo/dev).

  tags = {
    Name        = "pgadmin-admin-password"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "pgadmin" {
  secret_id     = aws_secretsmanager_secret.pgadmin.id
  secret_string = random_password.pgadmin.result
}

# Mot de passe RDS : généré par Terraform (plutôt que délégué à RDS via
# manage_master_user_password, voir modules/rds/main.tf) pour maîtriser dès
# le départ le nom du secret Secrets Manager, sans étape de "pont" vers un
# nom auto-généré imprévisible par AWS.
resource "random_password" "odoo_db" {
  length           = 32
  special          = true
  override_special = "!#%&*+-=?^_"
}

resource "aws_secretsmanager_secret" "odoo_db_password" {
  name                    = "odoo-db-password"
  description             = "Mot de passe master de l'instance RDS main-db, consommé par External Secrets Operator (apps/odoo)."
  recovery_window_in_days = 0

  tags = {
    Name        = "odoo-db-password"
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "odoo_db_password" {
  secret_id     = aws_secretsmanager_secret.odoo_db_password.id
  secret_string = random_password.odoo_db.result
}

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name_prefix = "external-secrets-"

  attach_external_secrets_policy = true
  # Lecture seule (pas de create_permission) : ESO ne crée ni ne modifie de
  # secrets, il ne fait que les lire pour les recopier en Secret Kubernetes.
  external_secrets_secrets_manager_arns = [
    aws_secretsmanager_secret.odoo_db_password.arn,
    aws_secretsmanager_secret.pgadmin.arn,
  ]
  external_secrets_kms_key_arns = [data.aws_kms_alias.secretsmanager.target_key_arn]
  # Ni SSM Parameter Store, ni création de secrets : on désactive les droits
  # par défaut du module pour ces usages non nécessaires ici.
  external_secrets_ssm_parameter_arns = []

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }

  tags = {
    Name = "iam-role-external-secrets"
  }
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.10.7" # À vérifier contre la version publiée du chart avant l'apply.
  namespace        = "external-secrets"
  create_namespace = true
  atomic           = true
  cleanup_on_fail  = true
  # Ce chart crée aussi des Service (webhook, cert-controller), interceptés
  # par le webhook de mutation du contrôleur ALB tant qu'il n'est pas
  # pleinement prêt (même risque de course que pour l'addon coredns et
  # ArgoCD, voir alb-controller.tf et argocd.tf).
  depends_on = [module.eks, module.external_secrets_irsa, helm_release.aws_load_balancer_controller]

  values = [
    yamlencode({
      installCRDs = true
      serviceAccount = {
        create = true
        name   = "external-secrets"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.external_secrets_irsa.iam_role_arn
        }
      }
    })
  ]
}

# ClusterSecretStore : ressource personnalisée (CRD apporté par le chart
# ci-dessus) exposant AWS Secrets Manager à tout ExternalSecret du cluster,
# quel que soit son namespace. Créée via un mini chart Helm local, même
# technique que pour l'Application racine ArgoCD (charts/argocd-bootstrap) :
# évite un provider Terraform tiers pour les CRD (voir argocd.tf).
resource "helm_release" "external_secrets_cluster_store" {
  name       = "external-secrets-cluster-store"
  chart      = "${path.module}/charts/external-secrets-bootstrap"
  namespace  = "external-secrets"
  depends_on = [helm_release.external_secrets]

  values = [
    yamlencode({
      region = var.aws_region
    })
  ]
}
