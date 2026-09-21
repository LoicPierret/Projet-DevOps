# Hosted zone Route 53 du domaine de l'application. Elle est gérée ici (et non
# dans terraform/app) pour que ses serveurs de noms restent stables lors des
# cycles destroy/apply de l'infrastructure applicative : la délégation chez le
# registrar n'est à configurer qu'une seule fois.
module "route53" {
  source = "../modules/route53"

  domain_name = var.domain_name
  project     = var.project
  environment = var.environment
}
