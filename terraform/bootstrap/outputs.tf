output "state_bucket_name" {
  description = "Nom du bucket S3 utilisé comme backend Terraform."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN du bucket S3 utilisé comme backend Terraform."
  value       = aws_s3_bucket.terraform_state.arn
}

output "lock_table_name" {
  description = "Nom de la table DynamoDB utilisée pour le verrouillage du state."
  value       = aws_dynamodb_table.terraform_locks.name
}

output "lock_table_arn" {
  description = "ARN de la table DynamoDB utilisée pour le verrouillage du state."
  value       = aws_dynamodb_table.terraform_locks.arn
}

output "github_actions_role_arn" {
  description = "ARN du rôle IAM assumable via OIDC par GitHub Actions. À renseigner dans le secret GitHub AWS_IAM_ROLE_ARN."
  value       = aws_iam_role.github_actions_cicd.arn
}

output "github_actions_oidc_provider_arn" {
  description = "ARN du fournisseur OIDC GitHub Actions enregistré dans IAM."
  value       = aws_iam_openid_connect_provider.github_actions.arn
}
