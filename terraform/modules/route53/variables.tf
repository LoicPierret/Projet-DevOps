variable "domain_name" {
  description = "Nom de domaine de la hosted zone publique (ex: nuages.click)."
  type        = string
}

variable "comment" {
  description = "Commentaire associé à la hosted zone."
  type        = string
  default     = "Managed by Terraform"
}

variable "force_destroy" {
  description = "Supprime tous les enregistrements de la zone lors de sa destruction. À laisser à false en production."
  type        = bool
  default     = false
}

variable "project" {
  description = "Nom du projet, utilisé pour l'étiquetage des ressources."
  type        = string
}

variable "environment" {
  description = "Environnement cible (dev, staging, prod), utilisé pour l'étiquetage des ressources."
  type        = string
}

variable "tags" {
  description = "Tags additionnels à appliquer à la hosted zone."
  type        = map(string)
  default     = {}
}
