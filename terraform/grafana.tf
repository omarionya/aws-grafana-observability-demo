resource "grafana_dashboard" "lab" {
  config_json = jsonencode({
    uid           = "slow-checkout-lab"
    title         = "Slow Checkout Lab"
    tags          = ["lab"]
    schemaVersion = 39
    refresh       = "10s"
    time          = { from = "now-30m", to = "now" }
    panels = [for i, p in [
      { title = "Checkout requests / second", unit = "reqps", expr = "sum by (scenario) (rate(lab_requests_total{service=\"checkout\"}[1m]))" },
      { title = "Checkout duration: average seconds", unit = "s", expr = "sum by (scenario) (rate(lab_request_duration_seconds_sum{service=\"checkout\"}[1m])) / sum by (scenario) (rate(lab_request_duration_seconds_count{service=\"checkout\"}[1m]))" },
      { title = "Checkout errors / second", unit = "reqps", expr = "sum(rate(lab_errors_total{service=\"checkout\"}[1m]))" },
      { title = "Process CPU (one core = 100%)", unit = "percent", expr = "lab_process_cpu_percent" }
      ] : {
      id          = i + 1, type = "timeseries", title = p.title,
      datasource  = { type = "prometheus", uid = var.grafana_metrics_uid },
      gridPos     = { x = (i % 2) * 12, y = floor(i / 2) * 8, w = 12, h = 8 },
      fieldConfig = { defaults = { unit = p.unit }, overrides = [] },
      targets     = [{ refId = "A", expr = p.expr, legendFormat = "{{scenario}} {{service}}" }]
    }]
  })
}
