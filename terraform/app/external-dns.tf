# ExternalDNS : crée et nettoie automatiquement les enregistrements Route 53 à
# partir des hôtes déclarés dans les Ingress (déployés hors Terraform, par
# kubectl ou ArgoCD). Évite de référencer l'ALB, inexistant avant le déploiement
# de l'Ingress. Droits IAM limités à la hosted zone du domaine (main.tf).
module "external_dns_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name_prefix = "external-dns-"

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [data.aws_route53_zone.main.arn]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:external-dns"]
    }
  }

  tags = {
    Name = "iam-role-external-dns"
  }
}

resource "helm_release" "external_dns" {
  name            = "external-dns"
  repository      = "https://kubernetes-sigs.github.io/external-dns/"
  chart           = "external-dns"
  namespace       = "kube-system"
  version         = "1.15.0"
  depends_on      = [module.external_dns_irsa, helm_release.aws_load_balancer_controller]
  atomic          = true
  cleanup_on_fail = true

  values = [
    yamlencode({
      provider = {
        name = "aws"
      }
      sources       = ["ingress"]
      domainFilters = [var.domain_name]
      # "sync" supprime aussi les enregistrements lorsqu'un Ingress disparaît
      # (GitOps) ; seuls les enregistrements marqués par ce txtOwnerId sont gérés.
      policy     = "sync"
      registry   = "txt"
      txtOwnerId = module.eks.cluster_name
      extraArgs  = ["--aws-zone-type=public"]
      serviceAccount = {
        create = true
        name   = "external-dns"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.external_dns_irsa.iam_role_arn
        }
      }
    })
  ]
}
