# Fournisseur OIDC permettant à GitHub Actions de s'authentifier auprès d'AWS
# via des jetons temporaires (sts:AssumeRoleWithWebIdentity), sans clé d'accès
# long-lived stockée en secret GitHub.
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  tags = {
    Name        = "${var.project}-github-actions-oidc"
    Environment = var.environment
    Project     = var.project
    ManagedBy   = "Terraform"
  }
}

# Politique de confiance : seuls les workflows du dépôt GitHub configuré
# peuvent assumer ce rôle, et uniquement pour la branche main, les pull
# requests (terraform plan en CI) et le job utilisant l'environment
# GitHub "production" (job deploy de deploy.yml).
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    sid     = "AllowGithubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${var.github_repo}:pull_request",
        "repo:${var.github_org}/${var.github_repo}:environment:production",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_cicd" {
  name                 = "${var.project}-github-actions-cicd"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_trust.json
  max_session_duration = 3600

  tags = {
    Name        = "${var.project}-github-actions-cicd"
    Environment = var.environment
    Project     = var.project
    ManagedBy   = "Terraform"
  }
}

# Accès strict au backend Terraform : bucket S3 de state et table DynamoDB
# de verrouillage, scopés à leurs ARN respectifs.
data "aws_iam_policy_document" "github_actions_backend" {
  statement {
    sid    = "TerraformStateBucketAccess"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      aws_s3_bucket.terraform_state.arn,
      "${aws_s3_bucket.terraform_state.arn}/*",
    ]
  }

  statement {
    sid    = "TerraformLockTableAccess"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = [aws_dynamodb_table.terraform_locks.arn]
  }
}

resource "aws_iam_role_policy" "github_actions_backend" {
  name   = "terraform-backend-access"
  role   = aws_iam_role.github_actions_cicd.id
  policy = data.aws_iam_policy_document.github_actions_backend.json
}

# Noms utilisés par le module EKS pour dériver les préfixes de ses rôles IAM.
# À maintenir alignés avec terraform/app/main.tf (cluster_name) et
# terraform/modules/eks/main.tf (clé du node group "main").
locals {
  eks_cluster_name    = "main-cluster"
  eks_node_group_name = "main"
}

# Permissions de déploiement de l'infrastructure applicative (terraform/app) :
# réseau/EC2, EKS, RDS, ACM, Route53. Ces actions de création ne peuvent pas
# être scopées à des ARN connus à l'avance (les ressources n'existent pas
# encore lors du premier apply) : le Resource = "*" ci-dessous est une
# exception documentée et volontaire, limitée à ces services précis plutôt
# qu'ouverte à l'ensemble du compte (pas de "Action = *" global, pas d'IAM
# non scopé — voir statements suivants).
data "aws_iam_policy_document" "github_actions_infra" {
  statement {
    sid       = "NetworkAndComputeManagement"
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  statement {
    sid       = "EksClusterManagement"
    effect    = "Allow"
    actions   = ["eks:*"]
    resources = ["*"]
  }

  statement {
    sid       = "RdsManagement"
    effect    = "Allow"
    actions   = ["rds:*"]
    resources = ["*"]
  }

  statement {
    sid    = "CertificateAndDnsManagement"
    effect = "Allow"
    actions = [
      "acm:*",
      "route53:*",
      "elasticloadbalancing:Describe*",
    ]
    resources = ["*"]
  }

  # Rôles/policies IAM gérés par terraform/app, scopés par préfixe de nom (pas
  # de wildcard sur l'ensemble des rôles/policies du compte) :
  #  - IRSA (ebs-csi-*, alb-controller-*) : créés dans app/main.tf via
  #    iam-role-for-service-accounts-eks;
  #  - rôle du plan de contrôle, policy de chiffrement et rôle du node group :
  #    créés par le module terraform-aws-modules/eks (préfixes dérivés du nom du
  #    cluster et de la clé du node group, cf. local.eks_* ci-dessus).
  statement {
    sid    = "IamRoleAndPolicyManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:ListEntitiesForPolicy",
      "iam:TagPolicy",
    ]
    resources = [
      "arn:aws:iam::*:role/ebs-csi-*",
      "arn:aws:iam::*:role/alb-controller-*",
      "arn:aws:iam::*:policy/ebs-csi-*",
      "arn:aws:iam::*:policy/alb-controller-*",
      "arn:aws:iam::*:role/${local.eks_cluster_name}-cluster-*",
      "arn:aws:iam::*:policy/${local.eks_cluster_name}-cluster-*",
      "arn:aws:iam::*:role/${local.eks_node_group_name}-eks-node-group-*",
    ]
  }

  # iam:PassRole : nécessaire pour associer les rôles au cluster EKS, au node
  # group et aux add-ons (service_account_role_arn de aws-ebs-csi-driver).
  statement {
    sid     = "PassRoleToEksResources"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::*:role/ebs-csi-*",
      "arn:aws:iam::*:role/alb-controller-*",
      "arn:aws:iam::*:role/${local.eks_cluster_name}-cluster-*",
      "arn:aws:iam::*:role/${local.eks_node_group_name}-eks-node-group-*",
    ]
  }

  # Rôles liés aux services (créés automatiquement au premier usage dans un
  # compte neuf), limités aux services réellement utilisés.
  statement {
    sid       = "ServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::*:role/aws-service-role/*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "eks.amazonaws.com",
        "eks-nodegroup.amazonaws.com",
        "autoscaling.amazonaws.com",
        "elasticloadbalancing.amazonaws.com",
        "rds.amazonaws.com",
      ]
    }
  }

  # Clé KMS de chiffrement des secrets du cluster (create_kms_key = true par
  # défaut dans le module EKS). L'ARN de la clé n'existant pas avant le premier
  # apply (et kms:CreateKey n'étant pas scopable), Resource = "*" est ici une
  # exception documentée.
  statement {
    sid    = "EksSecretsEncryptionKey"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:DescribeKey",
      "kms:GetKeyPolicy",
      "kms:PutKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:EnableKeyRotation",
      "kms:ListResourceTags",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CreateGrant",
      "kms:CreateAlias",
      "kms:DeleteAlias",
      "kms:ListAliases",
    ]
    resources = ["*"]
  }

  # Groupe de logs du plan de contrôle EKS (/aws/eks/<cluster>/cluster).
  statement {
    sid    = "EksControlPlaneLogGroup"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:PutRetentionPolicy",
      "logs:DeleteRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource",
      "logs:ListTagsForResource",
      "logs:ListTagsLogGroup",
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:/aws/eks/${local.eks_cluster_name}/cluster",
      "arn:aws:logs:*:*:log-group:/aws/eks/${local.eks_cluster_name}/cluster:*",
    ]
  }

  statement {
    sid       = "DescribeLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:aws:logs:*:*:log-group:*"]
  }

  # Fournisseur OIDC du cluster EKS,
  # créé par le module EKS (enable_irsa = true) et consommé par les rôles IRSA.
  statement {
    sid    = "EksOidcProviderManagement"
    effect = "Allow"
    actions = [
      "iam:CreateOpenIDConnectProvider",
      "iam:DeleteOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:AddClientIDToOpenIDConnectProvider",
    ]
    resources = ["arn:aws:iam::*:oidc-provider/*"]
  }
}

resource "aws_iam_role_policy" "github_actions_infra" {
  name   = "app-infra-deployment"
  role   = aws_iam_role.github_actions_cicd.id
  policy = data.aws_iam_policy_document.github_actions_infra.json
}
