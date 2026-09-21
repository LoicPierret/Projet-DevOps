variable "domain_name" {
  description = "Le nom de domaine principal (ex: nuages.click)"
  type        = string
}

variable "zone_id" {
  description = "Identifiant de la hosted zone Route 53 utilisée pour la validation DNS du certificat."
  type        = string
}

variable "environment" {
  description = "L'environnement (dev, prod, stag)"
  type        = string
  default     = "prod"
}