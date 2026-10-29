# AWS and Grafana Cloud Observability Lab

A small Terraform project that runs a two-service Python application on AWS and sends its telemetry to both AWS observability services and Grafana Cloud. The lab demonstrates how to investigate slow requests, application failures, and CPU-intensive code using metrics, logs, traces, and profiles.

**Scope:** one EC2 instance, Docker Compose, two application services, one OpenTelemetry Collector, and two observability backends. Target duration is approximately two hours once accounts, permissions, and local tools are ready.

## What this project helps solve

A slow or failed request rarely has a single useful explanation in a dashboard. This project connects four views of the same workload:

- **Metrics:** When did latency, errors, or CPU usage increase?
- **Logs:** What happened during a particular request?
- **Traces:** Which service or operation introduced the delay?
- **Profiles:** Which function consumed CPU time?

The same workload is exported to AWS and Grafana Cloud so their investigation workflows can be compared without deploying two separate applications.

## Architecture and telemetry collection

```text
Traffic generator
       |
       v
Checkout API ------ HTTP ------> Inventory API
       |                              |
       +------ metrics/logs/traces ----+
                         |
                         v
              OpenTelemetry Collector
                 /               \
                v                 v
         AWS observability    Grafana Cloud OTLP
         - CloudWatch metrics - Cloud Metrics / Mimir
         - CloudWatch logs    - Cloud Logs / Loki
         - X-Ray traces       - Cloud Traces / Tempo

Both Python services also send profiles directly:
  CodeGuru agents  ------> AWS CodeGuru Profiler
  Pyroscope agents ------> Grafana Cloud Profiles
```

The application runs in Docker containers on an **Amazon Linux 2023 EC2 instance**, using `t3.small` by default. Grafana Cloud stores and visualizes telemetry; it does not host the application.

Python OpenTelemetry instrumentation records HTTP requests and custom spans. Custom counters and a histogram record request volume, errors, and duration. JSON application logs include `trace_id`, its X-Ray equivalent, service, scenario, response status, and duration. The collector receives OTLP over HTTP on container port `4318` and exports to both backends. AWS application metrics are published through CloudWatch Embedded Metric Format (EMF).

Profiles follow separate pipelines using the CodeGuru and Pyroscope SDKs. They do not pass through this lab's OTLP collector. Application metrics are exported every 10 seconds; collection, batching, and backend processing add visibility delay. Profiling needs a sustained workload and can take several minutes to appear.

## Services and features used

| Component | Role in the lab |
|---|---|
| Terraform | Creates infrastructure, packages the runtime, and provisions both dashboards |
| EC2, VPC, subnet, internet gateway | Hosts the containers and provides outbound connectivity |
| IAM instance role | Grants AWS access without static AWS keys in containers |
| Systems Manager Session Manager | Provides instance access without SSH or inbound security-group rules |
| SSM Parameter Store SecureString | Stores Grafana ingestion credentials outside Terraform state |
| Private S3 bucket | Holds the application bundle downloaded during instance startup |
| Cloud-init and systemd | Install dependencies and start Docker Compose |
| CloudWatch Metrics and dashboard | Display application metrics and native EC2 CPU utilization |
| CloudWatch Logs and Logs Insights | Store and query application JSON logs and EMF records |
| AWS X-Ray | Shows distributed traces and service relationships |
| CodeGuru Profiler | Collects AWS-side runtime profiles when enabled and available |
| Grafana Cloud Metrics, Logs, Traces, Profiles | Store and explore the four telemetry signals |
| Grafana dashboard, Explore, PromQL, LogQL, TraceQL | Support visualization and investigation |

CloudWatch Application Signals, Grafana Adaptive Telemetry, and Grafana Fleet Management are not configured by this project.

## Why dashboards exist in both AWS and Grafana

The duplicate dashboards are intentional: this is an **evaluation lab**. They let you compare how each platform presents the same application's behavior, how quickly an issue can be investigated, and how much setup is required.

The collector sends application telemetry to each backend independently. The Grafana dashboard queries Grafana Cloud Metrics; it does not read the CloudWatch dashboard. Dashboard duplication and telemetry duplication are separate decisions.

The dashboards are comparable, rather than identical. AWS shows requests per minute and native EC2 CPU; Grafana shows requests per second and application-process CPU. Multiply requests/second by 60 when comparing request volume. Host CPU and process CPU have different meanings and should not be compared as equivalent values. Both dashboards use average request duration.

For production, choose a primary operational dashboard and keep a second only when it has a clear audience or purpose. Sending telemetry to two destinations increases ingestion, storage, and maintenance costs.

## Repository layout

```text
terraform/                 AWS resources, dashboards, bootstrap, and outputs
runtime/app/               Flask application, instrumentation, and profilers
runtime/compose.yaml       Checkout, inventory, and collector containers
runtime/collector.yaml     OTLP receiver and exporters for both backends
runtime/traffic.py         Controlled traffic generator
secrets.env.example        Template for ingestion credentials
comparison.md              Evaluation worksheet
VALIDATION.md              Checks completed and validation limitations
```

## Setup

### 1. Prepare your local terminal

Install Terraform 1.5+, AWS CLI v2, Python 3, and the AWS Session Manager plugin. Authenticate AWS CLI against a sandbox account with permission to provision the resources listed above and pass the instance role.

Open a terminal **at the extracted project root**, then save its real location. The commands below use that path rather than assuming where you extracted the project:

```bash
export PROJECT_DIR="$(pwd)"
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION="$AWS_REGION"

aws sts get-caller-identity
terraform version
session-manager-plugin --version
```

Use your deployment region consistently if you change `us-east-1`. Check CodeGuru access before deploying:

```bash
aws codeguruprofiler list-profiling-groups --region "$AWS_REGION"
```

You can disable CodeGuru if unavailable, but then AWS-side profiling remains outside the completed comparison.

### 2. Configure Grafana credentials

Obtain the OTLP endpoint and ingestion credentials from your Grafana Cloud stack's OpenTelemetry configuration. Create a token with `metrics:write`, `logs:write`, and `traces:write`. Get the separate profiles URL, numeric user ID, and a `profiles:write` token from Profiles/Pyroscope setup.

```bash
cp "$PROJECT_DIR/secrets.env.example" "$PROJECT_DIR/secrets.env"
chmod 600 "$PROJECT_DIR/secrets.env"
nano "$PROJECT_DIR/secrets.env"
```

Fill in:

```dotenv
GRAFANA_OTLP_ENDPOINT=https://YOUR-OTLP-HOST/otlp
GRAFANA_OTLP_AUTH=Basic BASE64_OF_OTLP_INSTANCE_ID_COLON_INGESTION_TOKEN
PYROSCOPE_SERVER_ADDRESS=https://YOUR-PROFILES-HOST
PYROSCOPE_USERNAME=YOUR_PROFILES_INSTANCE_ID
PYROSCOPE_TOKEN=YOUR_PROFILES_WRITE_TOKEN
```

Use the exact endpoints from the same stack. The OTLP endpoint is a base URL, without `/v1/metrics` or another signal-specific suffix. The Authorization value uses a literal space after `Basic`, without `Authorization=` or `%20`.

To generate the Base64 value safely, run locally:

```bash
python3 - <<'PY'
import base64, getpass
user = input('OTLP instance ID: ').strip()
token = getpass.getpass('Ingestion token: ').strip()
print('GRAFANA_OTLP_AUTH=Basic ' + base64.b64encode(f'{user}:{token}'.encode()).decode())
PY
```

The generated value is also a credential. Copy it into the file and keep it private. Upload the file to Parameter Store:

```bash
aws ssm put-parameter \
  --name /slow-checkout-lab/env \
  --type SecureString \
  --value "file://$PROJECT_DIR/secrets.env" \
  --overwrite --region "$AWS_REGION"
```

For Terraform dashboard provisioning, create a **Grafana service account token with Editor permissions**. This is separate from ingestion credentials:

```bash
export GRAFANA_URL="https://YOUR-STACK.grafana.net"
read -rsp 'Grafana Editor service account token: ' GRAFANA_AUTH
printf '\n'
export GRAFANA_AUTH
```

Run Terraform in this same terminal without `sudo`. The variable name must be `GRAFANA_AUTH`.

### 3. Configure and apply Terraform

In Grafana, open **Connections → Data sources**, select the Cloud Prometheus source, and copy its UID from the URL after `/edit/`.

```bash
cp "$PROJECT_DIR/terraform/terraform.tfvars.example" \
  "$PROJECT_DIR/terraform/terraform.tfvars"
nano "$PROJECT_DIR/terraform/terraform.tfvars"
```

Set the deployment values:

```hcl
aws_region          = "us-east-1"
instance_type       = "t3.small"
grafana_metrics_uid = "YOUR_CLOUD_PROMETHEUS_UID"
enable_codeguru     = true
```

Review and apply:

```bash
terraform -chdir="$PROJECT_DIR/terraform" init
terraform -chdir="$PROJECT_DIR/terraform" validate
terraform -chdir="$PROJECT_DIR/terraform" plan -out=lab.tfplan
terraform -chdir="$PROJECT_DIR/terraform" apply lab.tfplan
terraform -chdir="$PROJECT_DIR/terraform" output
```

Terraform uploads the runtime bundle to S3. EC2 startup downloads it, reads the SSM secret, and starts the containers. Allow several minutes for bootstrap. Fixed resource names make this a single-lab deployment per account/region and Grafana stack.

### 4. Connect and verify startup

From your local terminal:

```bash
aws ssm start-session \
  --target "$(terraform -chdir="$PROJECT_DIR/terraform" output -raw instance_id)" \
  --region "$AWS_REGION"
```

Alternatively, use **AWS Console → EC2 → instance → Connect → Session Manager**. This avoids needing the plugin locally.

The following commands run **inside the EC2 session**. Application files are located at `/opt/slow-checkout-lab`:

```bash
sudo cloud-init status --wait
sudo docker compose -f /opt/slow-checkout-lab/compose.yaml ps -a
curl -i 'http://127.0.0.1:8080/checkout?scenario=normal'
```

Expect HTTP 200 and an `X-Trace-Id` response header. `Connection: close` is normal for the lab server. A trace ID confirms local trace generation, not successful export.

If startup failed:

```bash
sudo tail -n 80 /var/log/cloud-init-output.log
sudo journalctl -u slow-checkout-lab -n 80 --no-pager
```

### 5. Generate test traffic

Run inside EC2. Full paths avoid failures when Session Manager starts in a directory such as `/usr/bin`:

```bash
python3 /opt/slow-checkout-lab/traffic.py --scenario normal --seconds 120
python3 /opt/slow-checkout-lab/traffic.py --scenario slow --seconds 120
python3 /opt/slow-checkout-lab/traffic.py --scenario cpu --seconds 300
python3 /opt/slow-checkout-lab/traffic.py --scenario error --seconds 120
```

| Scenario | Expected behavior | Evidence to find |
|---|---|---|
| Normal | Successful checkout | HTTP 200, checkout → inventory trace |
| Slow | Inventory sleeps for 500 ms | Increased latency and long `inventory.lookup` span |
| CPU | Checkout calculates for roughly 250 ms | CPU increase and `expensive_calculation` profile hotspot |
| Error | Deliberate payment failure | HTTP 500, error metric, exception span, JSON error log |

## Investigate the results

Use the dashboard URLs printed by Terraform and select a time range covering the traffic run.

**Grafana metrics:** open Explore, select your Cloud Prometheus source, and first check whether any lab metrics exist:

```promql
{__name__=~"lab_.*"}
```

Then inspect request rate:

```promql
sum by (scenario) (rate(lab_requests_total{service="checkout"}[5m]))
```

**Grafana logs:** choose the Loki source:

```logql
{service_name="checkout"} | json
```

**Grafana traces:** search the Tempo source by a log's `trace_id`, or use TraceQL:

```traceql
{ resource.service.name = "checkout" }
```

**AWS metrics:** open the CloudWatch dashboard or namespace `SlowCheckoutLab`.

**AWS logs:** select `/slow-checkout-lab/app` in Logs Insights:

```sql
fields @timestamp, service, scenario, status, duration_ms, trace_id, xray_trace_id
| sort @timestamp desc
| limit 50
```

**AWS traces:** open CloudWatch in the deployment region, then **X-Ray traces → Traces**. Filter with `service("checkout")` and inspect a trace's timeline. The log's `xray_trace_id` is the AWS-formatted lookup ID.

**Profiles:** inspect the CPU-test window in Grafana Profiles/Pyroscope and CodeGuru profiling group `slow-checkout-lab`. Look for `expensive_calculation`. Both services share the AWS profiling group. CPU-only profiles should highlight calculation work rather than the inventory sleep.

## Challenges encountered and workarounds

| Challenge | Cause or interpretation | Workaround |
|---|---|---|
| Grafana provider requires `auth` and `url` | Terraform lacks provider credentials | Set `GRAFANA_URL` and `GRAFANA_AUTH` in the same shell; use an Editor service account token |
| `GRAFANA_AUTH` is empty | Misspelled variable, shell mismatch, or failed prompt | Verify with `test -n "$GRAFANA_AUTH" && echo set`; do not print the token |
| Session Manager plugin not found | AWS CLI plugin missing on the calling machine | Install the matching local OS/architecture package, or use the browser Session Manager |
| `no configuration file found` | Compose was run outside the application directory | Always use `-f /opt/slow-checkout-lab/compose.yaml` |
| Cannot open `/usr/bin/traffic.py` | Relative script path resolved from the wrong directory | Use `/opt/slow-checkout-lab/traffic.py` |
| Grafana panels empty; collector reports HTTP 401 | Grafana rejected the OTLP credentials | Correct the OTLP instance ID, ingestion token, write scopes, and Basic header; recreate the collector |
| Collector logs empty with `--since=2m` | No recent log entries; success is normally quiet | Check container status, generate traffic, and query Explore to confirm ingestion |
| Explore has metrics but dashboard is empty | Possible data source, time range, label, or metric-name mismatch | Select the correct Prometheus UID and inspect actual `lab_` names; OTLP translation can add suffixes |
| Profiles initially empty | Separate profile credentials, profiler errors, or ingestion delay | Check application logs and sustain CPU traffic for several minutes |

A 401 error was observed during this lab and caused metrics to be dropped. A later quiet collector log does not, by itself, prove the issue was resolved. Confirm delivery in Grafana Explore before marking ingestion successful.

### Recover from Grafana HTTP 401

Generate valid OTLP credentials, then edit the EC2 environment file:

```bash
sudo nano /opt/slow-checkout-lab/.env
sudo docker compose -f /opt/slow-checkout-lab/compose.yaml \
  up -d --force-recreate collector
```

Recreating the container loads changed environment variables; a restart alone does not. Inspect fresh logs:

```bash
sudo docker compose -f /opt/slow-checkout-lab/compose.yaml \
  logs --since=2m --tail=80 collector
```

Update the local `secrets.env` and upload it to the same SSM parameter as well, so a replacement instance receives the corrected credentials. Updating SSM alone does not refresh existing containers. Previously dropped batches are not replayed; generate fresh traffic after the fix.

## Acceptance criteria and evidence

Use `comparison.md` to record results rather than assuming success from deployment alone.

- [ ] All three containers remain running.
- [ ] Each traffic scenario returns its expected status.
- [ ] Application metrics appear in CloudWatch and Grafana Explore.
- [ ] JSON application logs appear in CloudWatch and Loki.
- [ ] A trace contains both checkout and inventory in AWS and Grafana.
- [ ] The calculation hotspot appears in both profiling backends.
- [ ] Dashboard panels cover the selected test window.

## Evidence

See [screenshots and test results](docs/evidence.md) for dashboards,
traces, error investigation, and profiling results.



## Security, cost, and limitations

No inbound security-group rules are opened. SSM provides shell access, and the checkout port is published only on EC2 loopback. IAM roles supply AWS credentials. The SecureString is deliberately outside Terraform state, but decrypted ingestion credentials exist in EC2's root-readable `.env` file and container environments. Keep secrets, state, and plan files out of version control.

The lab incurs EC2, disk, public IPv4, telemetry, and potentially profiling charges. Application/EMF log retention is one day. Dual export increases backend usage. A short lab does not establish representative monthly costs.

Both profilers run simultaneously, so their independent overhead cannot be measured from this setup. Automatic trace-to-profile links and dashboard exemplars are not configured; use manual trace IDs to correlate logs and traces. The Flask development server, fixed names, local Terraform state, and non-durable collector queues are appropriate for a disposable lab, not a production deployment.

See `VALIDATION.md` for the original local checks. Terraform provider/runtime verification was blocked in the authoring environment; observed deployment troubleshooting is documented separately above.

## Cleanup

Exit the EC2 session. In your local terminal, with the project path and AWS/Grafana credentials still set:

```bash
terraform -chdir="$PROJECT_DIR/terraform" plan -destroy
terraform -chdir="$PROJECT_DIR/terraform" destroy
aws ssm delete-parameter --name /slow-checkout-lab/env --region "$AWS_REGION"
unset GRAFANA_AUTH
```

Terraform removes the lab infrastructure and dashboards. Delete the SSM parameter separately and revoke temporary Grafana tokens. The existing Grafana stack and its data sources remain. Previously ingested Grafana and X-Ray data follow their backend retention policies. Keep Terraform state until cleanup succeeds.

