## Running Application

Terminal showing all three containers running and a successful checkout response.

![All the three containers running](images/running-app.png)

## AWS Dashboard

AWS  and Grafana receive application and infrastructure metrics


![Metrics Dashboard](images/aws-dashboard.png)

![Metrics Dashboard](images/grafana-dashboard.png)


## Slow Distributed Trace

Inventory adds a deliberate 500 ms delay.The trace places the delay Inventory is responsible for the increased checkout latency.

![Slow dependency trace](images/slow-trace.png)

## Correlated Failure

An error log with its trace ID and the matching error trace	Logs and traces can be connected to investigate a failed request

![An error log with its trace ID and the matching error trace](images/failure-trace.png)

## Profile Hotspot

CodeGuru and grafana flame graph highlighting expensive_calculation, Profiling identifies the deliberately expensive function

![Profile Hotspot for AWS](images/profile-hotspot-aws.png)


![Profile Hotspot for Grafana](images/profile-hotspot-grafana.png)




