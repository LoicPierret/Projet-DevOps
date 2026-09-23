# AWS Load Balancer Controller : provisionne un ALB pour chaque Ingress créé
# dans le cluster (Kubernetes, hors Terraform).
module "aws_load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name_prefix                       = "alb-controller-"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = {
    Name = "iam-role-alb-controller"
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.10.1"
  # depends_on sur le module entier (pas seulement l'IRSA) : le webhook de
  # mutation de ce chart intercepte TOUT Service créé dans le cluster dès son
  # enregistrement, avant même que ses pods ne soient prêts (failurePolicy
  # Fail par défaut). S'il démarre en parallèle des addons EKS (coredns
  # notamment, qui crée aussi un Service), leur création peut être rejetée
  # par un webhook pas encore opérationnel. On attend donc que tout
  # module.eks (cluster, nœuds, addons) soit terminé avant de l'installer.
  depends_on      = [module.eks, module.aws_load_balancer_controller_irsa]
  replace         = true
  atomic          = true
  cleanup_on_fail = true

  values = [
    yamlencode({
      clusterName = module.eks.cluster_name
      vpcId       = module.vpc.vpc_id
      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.aws_load_balancer_controller_irsa.iam_role_arn
        }
      }
    })
  ]
}
