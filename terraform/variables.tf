variable "aws_region" {
  type    = string
  default = "us-east-1"
}
variable "instance_type" {
  type    = string
  default = "t3.small"
}
variable "secret_parameter_name" {
  type    = string
  default = "/slow-checkout-lab/env"
}
variable "enable_codeguru" {
  type    = bool
  default = true
}
variable "grafana_metrics_uid" {
  type        = string
  description = "UID of the existing Grafana Cloud Prometheus data source."
}
