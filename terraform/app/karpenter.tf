# Karpenter : autoscaling des nœuds EKS. Retenu plutôt que Cluster
# Autoscaler (l'outil historique, qui pilote un Auto Scaling Group) : c'est
# aujourd'hui l'outil recommandé par AWS pour EKS (appel direct à l'API EC2,
# pas d'ASG intermédiaire, provisionnement plus rapide et plus fin par type
# d'instance).
#
# Choix assumé : pas de gestion des interruptions (pas de file SQS ni de
# règles EventBridge, ressources InterruptionPolicy du modèle IAM officiel de
# Karpenter volontairement exclues ci-dessous). Conséquence directe : le
# NodePool (charts/karpenter-bootstrap) est contraint à des instances
# On-Demand uniquement, jamais Spot, pour ne pas laisser des pods se faire
# couper sans préavis ni ré-ordonnancement propre. Les instances On-Demand
# peuvent malgré tout être ponctuellement récupérées par AWS (maintenance
# matérielle, "instance retirement") : un événement rare, déjà correctement
# absorbé par le contrôle-plane Kubernetes (le nœud est marqui prêt, un
# nouveau nœud est reprogrammé) sans nécessiter la réaction "propre" (drain
# avant coupure) que la file SQS apporte pour Spot.
#
# Le node group géré existant (module.eks, voir main.tf) devient un tout
# petit tier "système" à taille fixe (node_group_min/max/desired_size)
# hébergeant les composants de plateforme qui doivent tourner avant même que
# Karpenter puisse démarrer (CoreDNS, VPC CNI, kube-proxy, EBS CSI, ALB
# Controller, ArgoCD, ESO, la stack d'observabilité) ainsi que Karpenter
# lui-même. Aucun taint n'est posé sur ce tier ni node affinity sur les
# workloads applicatifs : Karpenter ne provisionne que la capacité
# manquante, sans isolation stricte système/applicatif (hors scope pour ce
# projet).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

# ─────────────────────────────────────────────────────────────────────────
# Rôle IAM assumé par les nœuds provisionnés par Karpenter (EC2)
# ─────────────────────────────────────────────────────────────────────────
# Nom fixe (pas de préfixe généré) : référencé explicitement, par nom, dans
# l'EC2NodeClass (charts/karpenter-bootstrap/templates/ec2nodeclass.yaml).
# Mêmes 4 policies managées que le node group existant (modules/eks/main.tf),
# à l'exception d'AmazonEC2ContainerRegistryReadOnly remplacée par
# ...PullOnly : c'est la policy que documente et utilise Karpenter lui-même
# (modèle IAM officiel), strictement suffisante pour un nœud qui ne fait que
# tirer des images.
resource "aws_iam_role" "karpenter_node" {
  name = "karpenter-node-${module.eks.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.${data.aws_partition.current.dns_suffix}" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "karpenter-node-${module.eks.cluster_name}"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

# Permet au kubelet des nœuds lancés sous ce rôle de rejoindre le cluster
# (équivalent, pour un rôle créé hors du node group managé, de l'aws-auth
# ConfigMap historique).
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"

  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────────────
# Rôle IAM (IRSA) du contrôleur Karpenter
# ─────────────────────────────────────────────────────────────────────────
# Policy personnalisée (aucune policy prédéfinie du module ne couvre
# Karpenter) : statements repris du modèle IAM officiel publié par le projet
# (template CloudFormation de la doc "Getting Started"), à l'exception des
# statements InterruptionPolicy (file SQS, hors scope ici) et ZonalShiftPolicy
# (fonctionnalité avancée non utilisée).
module "karpenter_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name_prefix = "karpenter-controller-"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["karpenter:karpenter"]
    }
  }

  tags = {
    Name = "iam-role-karpenter-controller"
  }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "karpenter-controller"
  role = module.karpenter_controller_irsa.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # --- NodeLifecyclePolicy : créer/étiqueter/détruire les instances EC2
      # que Karpenter lance, strictement scopé aux ressources qu'il possède
      # lui-même (tags kubernetes.io/cluster/<cluster>=owned et
      # karpenter.sh/nodepool présents).
      {
        Sid    = "AllowScopedEC2InstanceAccessActions"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}::image/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}::snapshot/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:security-group/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:subnet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:capacity-reservation/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:placement-group/*",
        ]
        Action = ["ec2:RunInstances", "ec2:CreateFleet"]
      },
      {
        Sid      = "AllowScopedEC2LaunchTemplateAccessActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:launch-template/*"
        Action   = ["ec2:RunInstances", "ec2:CreateFleet"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:spot-instances-request/*",
        ]
        Action = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                             = module.eks.cluster_name
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:spot-instances-request/*",
        ]
        Action = "ec2:CreateTags"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                             = module.eks.cluster_name
            "ec2:CreateAction"                                                = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*"
        Action   = "ec2:CreateTags"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
          StringEqualsIfExists = {
            "aws:RequestTag/eks:eks-cluster-name" = module.eks.cluster_name
          }
          "ForAllValues:StringEquals" = {
            "aws:TagKeys" = ["eks:eks-cluster-name", "karpenter.sh/nodeclaim", "Name"]
          }
        }
      },
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:*:launch-template/*",
        ]
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      # --- IAMIntegrationPolicy : passer le rôle nœud aux instances EC2, et
      # gérer (créer/étiqueter/détruire) le profil d'instance associé — que
      # Karpenter crée lui-même dynamiquement, aucun aws_iam_instance_profile
      # côté Terraform.
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Resource = aws_iam_role.karpenter_node.arn
        Action   = "iam:PassRole"
        Condition = {
          StringEquals = {
            "iam:PassedToService" = ["ec2.amazonaws.com", "ec2.amazonaws.com.cn"]
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileCreationActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Action   = ["iam:CreateInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                             = module.eks.cluster_name
            "aws:RequestTag/topology.kubernetes.io/region"                    = data.aws_region.current.region
          }
          StringLike = {
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileTagActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Action   = ["iam:TagInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"                    = data.aws_region.current.region
            "aws:RequestTag/kubernetes.io/cluster/${module.eks.cluster_name}"  = "owned"
            "aws:RequestTag/eks:eks-cluster-name"                              = module.eks.cluster_name
            "aws:RequestTag/topology.kubernetes.io/region"                     = data.aws_region.current.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"  = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Action   = ["iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile", "iam:DeleteInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${module.eks.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"                    = data.aws_region.current.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      # --- EKSIntegrationPolicy : découverte de l'endpoint du cluster
      # (utilisée à la place de settings.clusterEndpoint côté Helm, voir
      # helm_release.karpenter ci-dessous).
      {
        Sid      = "AllowAPIServerEndpointDiscovery"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:cluster/${module.eks.cluster_name}"
        Action   = "eks:DescribeCluster"
      },
      # --- ResourceDiscoveryPolicy : lecture seule, nécessaire à Karpenter
      # pour choisir un type d'instance, une AMI, un sous-réseau/SG...
      {
        Sid      = "AllowRegionalReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action = [
          "ec2:DescribeCapacityReservations",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribePlacementGroups",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
        ]
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = data.aws_region.current.region
          }
        }
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}::parameter/aws/service/*"
        Action   = "ssm:GetParameter"
      },
      {
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action   = "pricing:GetProducts"
      },
      {
        Sid      = "AllowUnscopedInstanceProfileListAction"
        Effect   = "Allow"
        Resource = "*"
        Action   = "iam:ListInstanceProfiles"
      },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:instance-profile/*"
        Action   = "iam:GetInstanceProfile"
      },
    ]
  })
}

# ─────────────────────────────────────────────────────────────────────────
# Tags de découverte : sous-réseaux privés et security group des nœuds,
# lus par les selectorTerms de l'EC2NodeClass (charts/karpenter-bootstrap).
# ─────────────────────────────────────────────────────────────────────────

resource "aws_ec2_tag" "karpenter_discovery_subnet" {
  # Indexé par position plutôt que par valeur : sur un premier apply (après
  # un destroy), le contenu de module.vpc.private_subnets n'est connu qu'à
  # l'apply, mais sa longueur (dérivée de var.azs) l'est dès le plan — un
  # for_each ne peut pas indexer sur des valeurs encore inconnues.
  for_each = { for idx, subnet_id in module.vpc.private_subnets : idx => subnet_id }

  resource_id = each.value
  key         = "karpenter.sh/discovery"
  value       = module.eks.cluster_name
}

resource "aws_ec2_tag" "karpenter_discovery_node_sg" {
  resource_id = module.eks.node_security_group_id
  key         = "karpenter.sh/discovery"
  value       = module.eks.cluster_name
}

# ─────────────────────────────────────────────────────────────────────────
# Contrôleur Karpenter
# ─────────────────────────────────────────────────────────────────────────

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.14.1" # À vérifier contre la version publiée du chart avant l'apply.
  namespace        = "karpenter"
  create_namespace = true
  atomic           = true
  cleanup_on_fail  = true
  # Même précaution que les autres charts créant des Service (webhook de
  # validation des CRD Karpenter) face au webhook de mutation du contrôleur
  # ALB pas encore pleinement prêt (voir alb-controller.tf). Attend aussi
  # l'access entry du rôle nœud : sans elle, un nœud Karpenter démarré avant
  # ne pourrait pas rejoindre le cluster.
  depends_on = [
    module.eks,
    module.karpenter_controller_irsa,
    aws_iam_role_policy.karpenter_controller,
    aws_eks_access_entry.karpenter_node,
    aws_ec2_tag.karpenter_discovery_subnet,
    aws_ec2_tag.karpenter_discovery_node_sg,
    helm_release.aws_load_balancer_controller,
  ]

  values = [
    yamlencode({
      settings = {
        clusterName = module.eks.cluster_name
        # Pas de clusterEndpoint : la policy IAM du contrôleur inclut
        # eks:DescribeCluster (AllowAPIServerEndpointDiscovery ci-dessus),
        # seule sa raison d'être documentée par Karpenter — l'endpoint est
        # découvert automatiquement à partir du nom du cluster.
      }
      serviceAccount = {
        create = true
        name   = "karpenter"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.karpenter_controller_irsa.iam_role_arn
        }
      }
      # 1 seule réplique : le tier système (module.eks, main.tf) tourne à
      # taille fixe très réduite, la contrainte anti-affinité par défaut du
      # chart (2 répliques sur 2 nœuds distincts) y laisserait une réplique
      # bloquée en Pending indéfiniment.
      replicas = 1
    })
  ]
}

# NodePool + EC2NodeClass par défaut : mêmes contraintes que pour ArgoCD/ESO
# (voir argocd.tf, external-secrets.tf), un provider Terraform tiers pour les
# CRD (alekc/kubectl) échoue au plan tant que l'hôte du cluster n'est pas
# encore connu.
resource "helm_release" "karpenter_default_nodepool" {
  name       = "karpenter-default-nodepool"
  chart      = "${path.module}/charts/karpenter-bootstrap"
  namespace  = "karpenter"
  depends_on = [helm_release.karpenter]

  values = [
    yamlencode({
      nodeRoleName  = aws_iam_role.karpenter_node.name
      clusterName   = module.eks.cluster_name
      instanceTypes = ["t3.medium", "t3.large"]
      cpuLimit      = "16"
      memoryLimit   = "64Gi"
    })
  ]
}
