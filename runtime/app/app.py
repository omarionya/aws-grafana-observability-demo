import json
import logging
import os
import secrets
import time

import psutil
import requests
from flask import Flask, jsonify, request, g
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk.trace.id_generator import IdGenerator

SERVICE = os.getenv("SERVICE_NAME", "checkout")
REGION = os.getenv("AWS_REGION", "us-east-1")
ENDPOINT = os.getenv("OTEL_ENDPOINT", "http://collector:4318")

# X-Ray accepts IDs with an epoch timestamp in the first 32 bits.
# W3C propagation keeps the same ID across both services and both backends.
class XRayCompatibleIdGenerator(IdGenerator):
    def generate_span_id(self):
        return secrets.randbits(64) or 1

    def generate_trace_id(self):
        return (int(time.time()) << 96) | secrets.randbits(96)

resource = Resource.create({
    "service.name": SERVICE,
    "deployment.environment": "lab",
    "cloud.provider": "aws",
    "cloud.region": REGION,
})
provider = TracerProvider(resource=resource, id_generator=XRayCompatibleIdGenerator())
provider.add_span_processor(BatchSpanProcessor(
    OTLPSpanExporter(endpoint=f"{ENDPOINT}/v1/traces")))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("slow-checkout-lab")
reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=f"{ENDPOINT}/v1/metrics"), export_interval_millis=10000)
metrics.set_meter_provider(MeterProvider(resource=resource, metric_readers=[reader]))
meter = metrics.get_meter("slow-checkout-lab")
request_count = meter.create_counter("lab_requests", unit="1")
error_count = meter.create_counter("lab_errors", unit="1")
duration = meter.create_histogram("lab_request_duration", unit="s")
process = psutil.Process()
meter.create_observable_gauge(
    "lab_process_cpu_percent", unit="%",
    callbacks=[lambda options: [metrics.Observation(
        process.cpu_percent(), {"service": SERVICE})]])

logs = LoggerProvider(resource=resource)
logs.add_log_record_processor(BatchLogRecordProcessor(
    OTLPLogExporter(endpoint=f"{ENDPOINT}/v1/logs")))
logger = logging.getLogger("lab")
logger.setLevel(logging.INFO)
logger.addHandler(LoggingHandler(level=logging.INFO, logger_provider=logs))
logger.addHandler(logging.StreamHandler())
logger.propagate = False

# Independent profile pipelines: these do not use the OTLP collector.
if os.getenv("PYROSCOPE_SERVER_ADDRESS"):
    import pyroscope
    pyroscope.configure(
        application_name=SERVICE,
        server_address=os.environ["PYROSCOPE_SERVER_ADDRESS"],
        basic_auth_username=os.environ["PYROSCOPE_USERNAME"],
        basic_auth_password=os.environ["PYROSCOPE_TOKEN"],
        tags={"environment": "lab", "region": REGION},
        sample_rate=100,
        oncpu=True,
        gil_only=True,
    )
if os.getenv("ENABLE_CODEGURU", "true").lower() == "true":
    from codeguru_profiler_agent import Profiler
    codeguru = Profiler(
        profiling_group_name=os.environ["CODEGURU_GROUP"],
        region_name=REGION,
    )
    codeguru.start()

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app, excluded_urls=".*/health")
RequestsInstrumentor().instrument()

@app.before_request
def begin_request():
    g.started = time.perf_counter()

@app.after_request
def finish_request(response):
    if request.path == "/health":
        return response
    scenario = request.args.get("scenario", "normal")
    if scenario not in {"normal", "slow", "cpu", "error"}:
        scenario = "invalid"
    elapsed = time.perf_counter() - g.started
    labels = {"service": SERVICE, "scenario": scenario}
    request_count.add(1, labels)
    duration.record(elapsed, labels)
    if response.status_code >= 500:
        error_count.add(1, labels)
    context = trace.get_current_span().get_span_context()
    trace_id = format(context.trace_id, "032x")
    event = {
        "service": SERVICE, "scenario": scenario, "path": request.path,
        "status": response.status_code, "duration_ms": round(elapsed * 1000, 2),
        "trace_id": trace_id,
        "xray_trace_id": f"1-{trace_id[:8]}-{trace_id[8:]}",
    }
    logger.log(logging.ERROR if response.status_code >= 500 else logging.INFO,
               json.dumps(event))
    response.headers["X-Trace-Id"] = trace_id
    return response

@app.get("/health")
def health():
    return {"status": "ok", "service": SERVICE}

def expensive_calculation(seconds=0.25):
    # Wall-clock bounded so the exercise also works on small EC2 instances.
    deadline = time.perf_counter() + seconds
    result = 0
    while time.perf_counter() < deadline:
        for value in range(10000):
            result += (value * value) % 97
    return result

@app.get("/inventory")
def inventory():
    if SERVICE != "inventory":
        return {"error": "wrong service"}, 404
    with tracer.start_as_current_span("inventory.lookup"):
        if request.args.get("scenario") == "slow":
            time.sleep(0.5)
        return {"available": True, "sku": "demo-001"}

@app.get("/checkout")
def checkout():
    if SERVICE != "checkout":
        return {"error": "wrong service"}, 404
    scenario = request.args.get("scenario", "normal")
    if scenario not in {"normal", "slow", "cpu", "error"}:
        return {"error": "scenario must be normal, slow, cpu or error"}, 400
    with tracer.start_as_current_span("checkout.process") as span:
        span.set_attribute("lab.scenario", scenario)
        try:
            stock = requests.get(
                "http://inventory:8080/inventory",
                params={"scenario": scenario}, timeout=3)
            stock.raise_for_status()
            if scenario == "cpu":
                with tracer.start_as_current_span("checkout.expensive_calculation"):
                    expensive_calculation()
            if scenario == "error":
                raise RuntimeError("deliberate payment failure")
            return jsonify(status="paid", inventory=stock.json())
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(trace.Status(trace.StatusCode.ERROR, str(exc)))
            return {"error": str(exc)}, 500

if __name__ == "__main__":
    # Lab server: one process avoids profiler initialization across forks.
    app.run(host="0.0.0.0", port=8080, threaded=True, use_reloader=False)
