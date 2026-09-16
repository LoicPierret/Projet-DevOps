variable "aws_region" {
  description = "AWS region to deploy infrastructure"
  type        = string
  default     = "us-east-1"
}
variable "azs" {
  type = list(string)
}

variable "cicd_iam_role_arn" {
  description = "ARN du rôle IAM utilisé par le pipeline CI/CD pour s'authentifier auprès du cluster EKS."
  type        = string
}

variable "db_password" {
  type        = string
  description = "Mot de passe RDS"
  sensitive   = true 
}