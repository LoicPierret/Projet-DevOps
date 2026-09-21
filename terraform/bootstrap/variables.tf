variable "aws_region" {
  description = "Région AWS où seront créées les ressources de bootstrap (bucket S3 et table DynamoDB)."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Nom du bucket S3 utilisé comme backend Terraform pour stocker le tfstate. Doit être unique globalement et correspondre au bucket déclaré dans app/provider.tf."
  type        = string
  default     = "terraform-bucket-loic"
}

variable "lock_table_name" {
  description = "Nom de la table DynamoDB utilisée pour le verrouillage (state locking) du backend S3. Doit correspondre à la table déclarée dans app/provider.tf."
  type        = string
  default     = "terraform-locks"
}

variable "project" {
  description = "Nom du projet, utilisé pour l'étiquetage des ressources."
  type        = string
  default     = "loic-infra"
}

variable "environment" {
  description = "Environnement cible (dev, staging, prod), utilisé pour l'étiquetage des ressources."
  type        = string
  default     = "prod"
}

variable "noncurrent_version_expiration_days" {
  description = "Nombre de jours après lesquels les versions non-courantes du bucket de state sont expirées, afin de maîtriser les coûts de stockage."
  type        = number
  default     = 90
}

variable "github_org" {
  description = "Organisation ou utilisateur GitHub propriétaire du dépôt autorisé à assumer le rôle CI/CD via OIDC."
  type        = string
  default     = "LoicPierret"
}

variable "github_repo" {
  description = "Nom du dépôt GitHub autorisé à assumer le rôle CI/CD via OIDC."
  type        = string
  default     = "Projet-DevOps"
}
