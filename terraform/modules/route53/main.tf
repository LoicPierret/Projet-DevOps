resource "aws_route53_zone" "this" {
  name          = var.domain_name
  comment       = var.comment
  force_destroy = var.force_destroy

  tags = merge(
    {
      Name        = var.domain_name
      Environment = var.environment
      Project     = var.project
      ManagedBy   = "Terraform"
    },
    var.tags
  )
}
