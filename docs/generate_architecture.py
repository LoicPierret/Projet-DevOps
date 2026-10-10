# Génère docs/architecture.png. Prérequis : `pip install diagrams` + Graphviz
# (binaire `dot` sur le PATH — `winget install Graphviz.Graphviz` sous Windows).
# Lancer depuis docs/ : `python generate_architecture.py`.
#
# Version lisible dans le README : le flux CI/CD (GitHub, rôle OIDC) est retiré
# du schéma, car il est déjà décrit juste en dessous dans le README.
# Le schéma se concentre sur l'infrastructure AWS, avec des textes plus grands.
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.network import Route53, ALB
from diagrams.aws.compute import EC2
from diagrams.aws.database import RDSPostgresqlInstance
from diagrams.aws.management import AmazonManagedPrometheus, AmazonManagedGrafana, CloudwatchLogs
from diagrams.aws.security import SecretsManager, ACM
from diagrams.onprem.gitops import ArgoCD
from diagrams.onprem.vcs import Github
from diagrams.onprem.client import Users
from diagrams.k8s.compute import Deploy, Pod
from diagrams.k8s.network import Ingress

graph_attr = {
    # dpi plus élevé : rend l'image avec plus de pixels, pour qu'elle reste
    # nette une fois réduite/affichée par GitHub — sans toucher aux
    # proportions police/icône (la lib diagrams fixe la taille de chaque
    # nœud indépendamment de fontsize ; l'agrandir fait déborder le texte
    # hors de sa boîte au lieu de l'agrandir proprement, constaté au premier
    # essai).
    "dpi": "220",
    "fontsize": "26",      # titres des zones (VPC, EKS...)
    "bgcolor": "white",
    "pad": "0.4",
    "splines": "ortho",
    "nodesep": "0.6",
    "ranksep": "1.0",
    "concentrate": "true",
}

node_attr = {"fontsize": "13"}
edge_attr = {"fontsize": "13"}

with Diagram(
    "Architecture AWS EKS",
    filename="architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
    outformat="png",
):
    users = Users("Utilisateurs")
    repo_gitops = Github("Dépôt GitOps")

    with Cluster("AWS"):
        dns = Route53("Route 53")

        with Cluster("VPC"):
            with Cluster("Sous-réseaux publics"):
                acm = ACM("ACM")
                alb = ALB("ALB")
                acm >> Edge(label="TLS") >> alb

            with Cluster("Sous-réseaux privés — EKS"):
                with Cluster("Tier système"):
                    argocd = ArgoCD("ArgoCD")
                    eso = EC2("External\nSecrets")
                    obs_agents = EC2("Prometheus\n+ Fluent Bit")
                    platform = EC2("Karpenter\n+ contrôleurs")

                with Cluster("Applications"):
                    ing = Ingress("Ingress")
                    odoo = Pod("Odoo")
                    webapp = Deploy("ic-webapp\n(HPA)")
                    pgadmin = Pod("pgAdmin")
                    ing >> [odoo, webapp, pgadmin]

                with Cluster("Nœuds à la demande"):
                    karpenter_nodes = EC2("EC2\n(Karpenter)")

            with Cluster("Sous-réseaux isolés"):
                rds = RDSPostgresqlInstance("RDS\nPostgreSQL")

        with Cluster("Services managés"):
            secrets = SecretsManager("Secrets\nManager")
            amp = AmazonManagedPrometheus("Managed\nPrometheus")
            amg = AmazonManagedGrafana("Managed\nGrafana")
            logs = CloudwatchLogs("CloudWatch\nLogs")

    users >> dns >> alb >> ing
    repo_gitops >> Edge(label="sync") >> argocd >> ing
    odoo >> rds
    eso >> secrets
    obs_agents >> amp
    obs_agents >> logs
    amg >> amp
    platform >> Edge(style="dashed") >> karpenter_nodes
