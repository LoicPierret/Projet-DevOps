output "amp_workspace_id" {
  description = "Identifiant du workspace Amazon Managed Prometheus."
  value       = aws_prometheus_workspace.main.id
}

output "amp_workspace_arn" {
  description = "ARN du workspace Amazon Managed Prometheus."
  value       = aws_prometheus_workspace.main.arn
}

output "amp_prometheus_endpoint" {
  description = "Endpoint du workspace AMP, à renseigner comme source de données Prometheus dans Grafana."
  value       = aws_prometheus_workspace.main.prometheus_endpoint
}

output "application_log_group_name" {
  description = "Nom du log group CloudWatch des logs applicatifs."
  value       = aws_cloudwatch_log_group.application_logs.name
}

output "grafana_workspace_id" {
  description = "Identifiant du workspace Amazon Managed Grafana."
  value       = aws_grafana_workspace.main.id
}

output "grafana_endpoint" {
  description = "URL du workspace Amazon Managed Grafana."
  value       = aws_grafana_workspace.main.endpoint
}
