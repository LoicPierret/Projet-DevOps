data "aws_route53_zone" "selected" {
  name         = var.domain_name
  private_zone = false
}

module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 5.0"

  domain_name = var.domain_name
  zone_id     = data.aws_route53_zone.selected.zone_id

  subject_alternative_names = [
    "*.${var.domain_name}"
  ]

  wait_for_validation = true
  validation_method = "DNS"

  tags = {
    Name        = "${var.domain_name}-cert"
    Environment = var.environment
  }
}