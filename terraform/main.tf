data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_availability_zones" "available" { state = "available" }
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}
locals {
  prefix    = "slow-checkout-lab"
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
}
resource "aws_vpc" "lab" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.prefix }
}
resource "aws_subnet" "lab" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}
resource "aws_internet_gateway" "lab" { vpc_id = aws_vpc.lab.id }
resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
}
resource "aws_route_table_association" "lab" {
  subnet_id      = aws_subnet.lab.id
  route_table_id = aws_route_table.lab.id
}
resource "aws_security_group" "lab" {
  name_prefix = "slow-checkout-lab-"
  vpc_id      = aws_vpc.lab.id
  description = "SSM access; no inbound connections"
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_iam_role" "lab" {
  name_prefix = "slow-checkout-lab-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.lab.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_iam_instance_profile" "lab" { role = aws_iam_role.lab.name }
resource "aws_cloudwatch_log_group" "app" {
  name              = "/slow-checkout-lab/app"
  retention_in_days = 1
}
resource "aws_cloudwatch_log_group" "metrics" {
  name              = "/slow-checkout-lab/metrics"
  retention_in_days = 1
}
resource "aws_codeguruprofiler_profiling_group" "lab" {
  count            = var.enable_codeguru ? 1 : 0
  name             = local.prefix
  compute_platform = "Default"
  agent_orchestration_config { profiling_enabled = true }
}
resource "aws_s3_bucket" "bundle" {
  bucket_prefix = "slow-checkout-lab-"
  force_destroy = true
}
resource "aws_s3_bucket_public_access_block" "bundle" {
  bucket                  = aws_s3_bucket.bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "bundle" {
  bucket = aws_s3_bucket.bundle.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
data "archive_file" "bundle" {
  type        = "zip"
  source_dir  = "${path.module}/../runtime"
  output_path = "${path.module}/lab.zip"
  excludes    = [".env", "app/__pycache__", "__pycache__"]
}
resource "aws_s3_object" "bundle" {
  bucket      = aws_s3_bucket.bundle.id
  key         = "lab.zip"
  source      = data.archive_file.bundle.output_path
  source_hash = data.archive_file.bundle.output_base64sha256
}
resource "aws_iam_role_policy" "lab" {
  role = aws_iam_role.lab.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = [aws_s3_object.bundle.arn] },
      { Effect = "Allow", Action = ["ssm:GetParameter"], Resource = ["arn:${local.partition}:ssm:${var.aws_region}:${local.account}:parameter${var.secret_parameter_name}"] },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = ["${aws_cloudwatch_log_group.app.arn}:*", "${aws_cloudwatch_log_group.metrics.arn}:*"] },
      { Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = ["*"] },
      { Effect = "Allow", Action = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"], Resource = ["*"] }
      ], var.enable_codeguru ? [
      { Effect = "Allow", Action = ["codeguru-profiler:ConfigureAgent", "codeguru-profiler:PostAgentProfile"], Resource = [aws_codeguruprofiler_profiling_group.lab[0].arn] }
    ] : [])
  })
}
resource "aws_instance" "lab" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.lab.id
  vpc_security_group_ids      = [aws_security_group.lab.id]
  iam_instance_profile        = aws_iam_instance_profile.lab.name
  associate_public_ip_address = true
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
  root_block_device {
    volume_size = 12
    volume_type = "gp3"
    encrypted   = true
  }
  user_data = templatefile("${path.module}/cloud-init.sh.tftpl", {
    region          = var.aws_region
    bucket          = aws_s3_bucket.bundle.id
    parameter       = var.secret_parameter_name
    enable_codeguru = tostring(var.enable_codeguru)
    bundle_hash     = data.archive_file.bundle.output_base64sha256
  })
  user_data_replace_on_change = true
  depends_on = [aws_iam_role_policy.lab, aws_iam_role_policy_attachment.ssm,
  aws_s3_object.bundle, aws_route_table_association.lab]
  tags = { Name = local.prefix }
}
