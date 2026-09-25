variable "cluster_name" {
  description = "Nom du cluster EKS supervisé (utilisé pour nommer les ressources : workspaces, log group, rôles IAM)."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN du fournisseur OIDC du cluster EKS, pour les rôles IRSA de Prometheus et Fluent Bit."
  type        = string
}

variable "aws_region" {
  description = "Région AWS de déploiement."
  type        = string
}

variable "environment" {
  description = "Environnement cible (dev, staging, prod), utilisé pour l'étiquetage des ressources."
  type        = string
}

variable "admin_user_email" {
  description = "Email de l'utilisateur IAM Identity Center à associer en tant qu'administrateur du workspace Amazon Managed Grafana."
  type        = string
}

variable "log_retention_days" {
  description = "Durée de rétention des logs applicatifs dans CloudWatch Logs."
  type        = number
  default     = 30
}

variable "monitoring_namespace" {
  description = "Namespace Kubernetes où sont installés Prometheus et Fluent Bit."
  type        = string
  default     = "monitoring"
}

variable "prometheus_chart_version" {
  description = "Version du chart Helm kube-prometheus-stack."
  type        = string
  default     = "65.5.1" # À vérifier contre la version publiée du chart avant l'apply.
}

variable "fluent_bit_chart_version" {
  description = "Version du chart Helm aws-for-fluent-bit."
  type        = string
  default     = "0.1.34" # À vérifier contre la version publiée du chart avant l'apply.
}
