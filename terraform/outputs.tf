output "instance_id" { value = aws_instance.lab.id }
output "ssm_command" {
  value = "aws ssm start-session --target ${aws_instance.lab.id} --region ${var.aws_region}"
}
output "cloudwatch_dashboard" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/slow-checkout-lab"
}
output "grafana_dashboard" { value = grafana_dashboard.lab.url }
