# Génère docs/architecture.png. Prérequis : `pip install diagrams` + Graphviz
# (binaire `dot` sur le PATH — `winget install Graphviz.Graphviz` sous Windows).
# Lancer depuis docs/ : `python generate_architecture.py`.
from diagrams import Diagram, Cluster, Edge
from diagrams.aws.network import Route53, ALB
from diagrams.aws.compute import EC2
from diagrams.aws.database import RDSPostgresqlInstance
from diagrams.aws.management import AmazonManagedPrometheus, AmazonManagedGrafana, CloudwatchLogs
from diagrams.aws.security import SecretsManager, ACM, IdentityAndAccessManagementIamRole
from diagrams.onprem.gitops import ArgoCD
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.vcs import Github
from diagrams.onprem.client import Users
from diagrams.k8s.compute import Deploy, Pod
from diagrams.k8s.network import Ingress

graph_attr = {
    "fontsize": "22",
    "bgcolor": "white",
    "pad": "0.4",
    "splines": "ortho",
    "nodesep": "0.6",
    "ranksep": "1.0",
    "concentrate": "true",
}

node_attr = {"fontsize": "12"}

with Diagram(
    "Architecture - AWS EKS (Option A)",
    filename="architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
    node_attr=node_attr,
    outformat="png",
):
    users = Users("Utilisateurs")

    with Cluster("GitHub"):
        repo_infra = Github("Projet-DevOps\n(infra + CI/CD)")
        repo_gitops = Github("GitOps_Kubernetes\n(manifests K8s)")
        gha = GithubActions("ci.yml / deploy.yml")
        repo_infra >> gha

    with Cluster("AWS (compte unique)"):
        ci_role = IdentityAndAccessManagementIamRole("Rôle CI\n(OIDC, moindre privilège)")
        gha >> Edge(label="AssumeRoleWithWebIdentity") >> ci_role
        dns = Route53("Route 53")

        with Cluster("VPC"):
            with Cluster("Sous-réseaux publics"):
                alb = ALB("ALB\n(AWS Load Balancer Controller)")
                acm = ACM("Certificat ACM")
                acm >> Edge(label="TLS") >> alb

            with Cluster("Sous-réseaux privés"):
                with Cluster("EKS - main-cluster"):
                    with Cluster("Tier système (1-2x t3.medium, fixe)"):
                        platform = EC2("CoreDNS, VPC CNI,\nALB Controller,\nKarpenter, metrics-server")
                        argocd = ArgoCD("ArgoCD")
                        eso = EC2("External Secrets\nOperator")
                        obs_agents = EC2("kube-prometheus-stack\n+ Fluent Bit")

                    with Cluster("Karpenter (nœuds à la demande,\nOn-Demand uniquement)"):
                        karpenter_nodes = EC2("Nœuds EC2\nprovisionnés dynamiquement")

                    with Cluster("Applications (namespace ic-webapp)"):
                        ing = Ingress("Ingress")
                        webapp = Deploy("ic-webapp\n(HPA 2-4, PDB)")
                        odoo = Pod("odoo\n(1 replica, PVC RWO)")
                        pgadmin = Pod("pg-admin\n(1 replica, PVC RWO)")
                        ing >> [webapp, odoo, pgadmin]

                    with Cluster("Secrets & supervision"):
                        secrets = SecretsManager("Secrets Manager\n(mots de passe générés)")
                        amp = AmazonManagedPrometheus("Amazon Managed\nPrometheus")
                        amg = AmazonManagedGrafana("Amazon Managed\nGrafana")
                        logs = CloudwatchLogs("CloudWatch Logs")
                        amg >> Edge(label="lit") >> amp
                        amg >> Edge(label="lit") >> logs

            with Cluster("Sous-réseaux isolés (pas d'accès Internet)"):
                rds = RDSPostgresqlInstance("RDS PostgreSQL\n(main-db)")

        ci_role >> Edge(label="terraform apply") >> alb
        ci_role >> rds
        alb >> ing
        users >> dns >> alb
        secrets >> Edge(style="dashed", label="master password") >> odoo
        eso >> Edge(label="lit") >> secrets
        obs_agents >> Edge(label="remote_write") >> amp
        obs_agents >> Edge(label="logs") >> logs
        repo_gitops >> Edge(label="scrutation 30s") >> argocd
        argocd >> Edge(label="sync") >> [webapp, odoo, pgadmin]
        platform >> Edge(label="provisionne", style="dashed") >> karpenter_nodes
