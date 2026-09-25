terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  access_entries = var.access_entries

  endpoint_public_access  = true
  endpoint_private_access = true

  addons = {
    vpc-cni = {
      before_compute = true
      # Sans ça, le nombre max de pods par nœud est calculé uniquement à
      # partir du nombre d'IP disponibles par ENI (t3.medium : 17 pods max),
      # une limite atteinte en pratique avec ArgoCD + kube-prometheus-stack +
      # Fluent Bit en plus des apps. Le "prefix delegation" alloue des blocs
      # d'IP entiers par ENI plutôt qu'une IP à la fois, augmentant fortement
      # cette limite sans changer de type d'instance ni ajouter de nœud.
      # N'affecte que les nœuds créés APRÈS ce changement (calculé une seule
      # fois, au démarrage du nœud) : sans effet sur les 2 nœuds déjà actifs.
      configuration_values = jsonencode({
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    coredns = {}
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
  }

  node_security_group_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  eks_managed_node_groups = {
    main = {
      min_size     = var.node_group_min_size
      max_size     = var.node_group_max_size
      desired_size = var.node_group_desired_size

      instance_types = var.node_group_instance_types
      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"

        AmazonEKS_CNI_Policy = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"

        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # Le nombre max de pods par nœud est calculé par nodeadm à partir d'une
      # table statique par type d'instance (17 pour t3.medium), SANS tenir
      # compte du prefix delegation activé sur le CNI (vpc-cni ci-dessus) :
      # constaté à l'apply, un nœud fraîchement créé avec le CNI en prefix
      # delegation a quand même récupéré max-pods=17. Il faut fournir la
      # valeur explicitement. Nos nœuds tournent en AL2023, qui utilise
      # nodeadm (pas l'ancien bootstrap.sh) : le réglage passe par un
      # document cloud-init "pre-nodeadm" au format NodeConfig, pas par
      # bootstrap_extra_args (ignoré sur AL2023).
      # 110 : valeur standard recommandée par l'outil AWS max-pods-
      # calculator.sh en prefix delegation, largement suffisante ici (bien
      # au-delà du nombre de pods réellement déployés).
      cloudinit_pre_nodeadm = [
        {
          content_type = "application/node.eks.aws"
          content = yamlencode({
            apiVersion = "node.eks.aws/v1alpha1"
            kind       = "NodeConfig"
            spec = {
              kubelet = {
                config = {
                  maxPods = 110
                }
              }
            }
          })
        }
      ]
    }
  }

  tags = merge(
    {
      "Name"        = var.cluster_name
      "Environment" = "prod"
    },
    var.tags
  )
}