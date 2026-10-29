resource "aws_cloudwatch_dashboard" "lab" {
  dashboard_name = "slow-checkout-lab"
  dashboard_body = jsonencode({
    widgets = [
      { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = {
        title   = "Checkout duration: average seconds", region = var.aws_region,
        view    = "timeSeries", stat = "Average", period = 60,
        metrics = [for s in ["normal", "slow", "cpu", "error"] : ["SlowCheckoutLab", "lab_request_duration", "service", "checkout", "scenario", s]]
      } },
      { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = {
        title   = "EC2 CPU", region = var.aws_region,
        view    = "timeSeries", stat = "Average", period = 300,
        metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.lab.id]]
      } },
      { type = "metric", x = 0, y = 6, width = 12, height = 6, properties = {
        title   = "Checkout requests per minute", region = var.aws_region,
        view    = "timeSeries", stat = "Sum", period = 60,
        metrics = [for s in ["normal", "slow", "cpu", "error"] : ["SlowCheckoutLab", "lab_requests", "service", "checkout", "scenario", s]]
      } },
      { type = "metric", x = 12, y = 6, width = 12, height = 6, properties = {
        title   = "Deliberate checkout errors per minute", region = var.aws_region,
        view    = "timeSeries", stat = "Sum", period = 60,
        metrics = [["SlowCheckoutLab", "lab_errors", "service", "checkout", "scenario", "error"]]
      } }
    ]
  })
}
