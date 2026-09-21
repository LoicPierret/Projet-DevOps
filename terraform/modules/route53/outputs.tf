output "zone_id" {
  description = "Identifiant de la hosted zone Route 53."
  value       = aws_route53_zone.this.zone_id
}

output "zone_arn" {
  description = "ARN de la hosted zone Route 53."
  value       = aws_route53_zone.this.arn
}

output "name" {
  description = "Nom de domaine de la hosted zone."
  value       = aws_route53_zone.this.name
}

output "name_servers" {
  description = "Serveurs de noms (NS) à configurer chez le registrar du domaine."
  value       = aws_route53_zone.this.name_servers
}
