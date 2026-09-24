# ArgoCD : contrôleur GitOps installé dans le cluster. Il synchronise en
# continu l'état déclaré dans le dépôt GitOps (var.gitops_repo_url) avec le
# cluster. Accès à l'UI en phase 1 via `kubectl port-forward` uniquement
# (aucune exposition Ingress/DNS pour ce composant à ce stade).
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.3" # À vérifier contre la version publiée du chart avant l'apply.
  namespace        = "argocd"
  create_namespace = true
  atomic           = true
  cleanup_on_fail  = true
  # Le chart ArgoCD crée plusieurs Service (argocd-server, repo-server,
  # redis...) : on attend que le contrôleur ALB soit pleinement opérationnel
  # (pods prêts, pas seulement installé) pour éviter le même risque de
  # webhook pas encore servi que pour l'addon coredns (voir alb-controller.tf).
  depends_on = [helm_release.aws_load_balancer_controller]

  values = [
    yamlencode({
      server = {
        # ClusterIP : pas d'exposition publique en phase 1, accès uniquement
        # via `kubectl port-forward svc/argocd-server -n argocd 8080:443`.
        service = {
          type = "ClusterIP"
        }
        extraArgs = [
          # Le port-forward parle en HTTP au pod ; ArgoCD sert du HTTPS par
          # défaut, ce qui casse le port-forward sans ce drapeau.
          "--insecure"
        ]
      }
      configs = {
        cm = {
          # Intervalle de scrutation du dépôt GitOps (défaut : 180s).
          # Alternative retenue à un webhook GitHub : même gain perçu de
          # réactivité, sans exposer publiquement argocd-server (toujours en
          # ClusterIP ci-dessus). Compromis assumé pour un dépôt à faible
          # fréquence de commits ; sans incidence sur le modèle pull de
          # GitOps, qui ne dépend que de qui écrit dans le cluster (ArgoCD
          # seul), pas de la façon dont il détecte un changement Git.
          "timeout.reconciliation" = "30s"
        }
      }
    })
  ]
}

# Application racine (pattern "app of apps") : ArgoCD lit ce chemin du dépôt
# GitOps et y découvre les manifests Application des applications réelles
# (ic-webapp, odoo, pgadmin, ...), qu'il crée et synchronise à son tour.
# Créée via un mini chart Helm local (charts/argocd-bootstrap) plutôt qu'un
# provider Terraform dédié aux CRD : le provider kubectl (alekc/kubectl)
# échoue au plan dès que le host du provider (module.eks.cluster_endpoint)
# n'est pas encore connu, faute de gérer les valeurs "known after apply" -
# contrairement au provider helm, déjà utilisé de façon fiable ci-dessus.
resource "helm_release" "argocd_root_app" {
  name       = "argocd-root-app"
  chart      = "${path.module}/charts/argocd-bootstrap"
  namespace  = "argocd"
  depends_on = [helm_release.argocd]

  values = [
    yamlencode({
      repoURL        = var.gitops_repo_url
      targetRevision = var.gitops_target_revision
      path           = var.gitops_bootstrap_path
    })
  ]
}
