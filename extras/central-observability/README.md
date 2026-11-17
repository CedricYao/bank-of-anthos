# Central Observability + Bank of Anthos

This directory contains a script for sending Bank of Anthos logs, metrics, and traces from the project it runs in to a separate, central observability project.

## How it works

The script connects two projects:

- **App project** (`PROJECT_ID`): runs the GKE cluster with Bank of Anthos, and Cloud SQL if you use the [Cloud SQL extra](../cloudsql/README.md).
- **Central project** (`CENTRAL_PROJECT_ID`): where operators view logs, dashboards, alerts, and traces.

Each signal is handled differently:

| Signal | Mechanism | Where the data is stored |
|---|---|---|
| Logs | A [log sink](https://cloud.google.com/logging/docs/export/configure_export_v2) in the app project routes entries to a [log bucket](https://cloud.google.com/logging/docs/buckets) in the central project. | Central project (copied) |
| Metrics | The app project is added to the central project's [metrics scope](https://cloud.google.com/monitoring/settings). | App project, queried from the central project |
| Traces | A [trace scope](https://cloud.google.com/trace/docs/trace-scope/create-and-manage) in the central project includes the app project, and is set as the central project's default. | App project, queried from the central project |

Google Cloud has no way to copy metrics or traces into another project, so for those signals the central project views the data where it is stored.

These logs are routed:

- GKE workload and cluster logs (`k8s_container`, `k8s_pod`, `k8s_node`, `k8s_cluster`, `gke_cluster`). These include stdout from every Bank of Anthos service and from the in-cluster Postgres databases.
- Cloud SQL logs (`cloudsql_database`), if you use Cloud SQL.
- Cloud Audit Logs.

## Prerequisites

1. **Two Google Cloud projects**: one running Bank of Anthos, and the central project.
2. **Permissions** for the account running the script:
   - App project: `roles/logging.configWriter`, `roles/monitoring.editor`, `roles/serviceusage.serviceUsageAdmin`, plus `roles/resourcemanager.projectIamAdmin` if you set `WORKLOAD_GSA`.
   - Central project: `roles/logging.admin`, `roles/monitoring.admin`, `roles/resourcemanager.projectIamAdmin`, `roles/serviceusage.serviceUsageAdmin`, plus permission to manage Observability scopes and trace scopes (`roles/owner` covers these).
3. **The Google Cloud CLI** with the `beta` component installed (`gcloud components install beta`).

## Setup

1. **Set environment variables** for your projects.

```
export PROJECT_ID="my-boa-project"
export CENTRAL_PROJECT_ID="my-central-observability-project"
```

2. **(Optional) Set extra variables** to customize the setup.

| Variable | Default | Description |
|---|---|---|
| `LOG_BUCKET` | `central-logs` | Destination log bucket in the central project. |
| `LOG_BUCKET_LOCATION` | `global` | Region of the log bucket. |
| `LOG_RETENTION_DAYS` | `30` | How long the bucket keeps logs. |
| `SINK_NAME` | `boa-to-central` | Name of the log sink in the app project. |
| `EXCLUDE_FROM_SOURCE` | `false` | If `true`, the app project's `_Default` bucket stops storing the routed logs, so you don't pay to store them twice. |
| `WORKLOAD_GSA` | _(unset)_ | The Google service account your Bank of Anthos pods use through Workload Identity, for example `boa-gsa@${PROJECT_ID}.iam.gserviceaccount.com`. If set, it is granted `roles/cloudtrace.agent` and `roles/monitoring.metricWriter`. |

3. **Run the script.** You can safely run it again: it creates missing resources and updates existing ones.

```
./setup_central_observability.sh
```

4. **Check the results** in the central project. Logs from a new sink can take a few minutes to appear.
   - **Logs:** open [Logs Explorer](https://console.cloud.google.com/logs/query), click **Refine scope**, and select the `central-logs` bucket.
   - **Metrics:** open [Metrics Explorer](https://console.cloud.google.com/monitoring/metrics-explorer). Metrics from the app project, such as `kubernetes.io/container/*` and `cloudsql.googleapis.com/*`, are available.
   - **Traces:** open [Trace Explorer](https://console.cloud.google.com/traces/explorer) and look for spans from `frontend`, `userservice`, `ledgerwriter`, and the other services.

## Traces from Bank of Anthos

Tracing is on by default: every service has `ENABLE_TRACING: "true"` in its Kubernetes manifest, and the services export spans to Cloud Trace in the app project. Spans only arrive if the pods' Google service account has `roles/cloudtrace.agent`:

- **[Cloud SQL extra](../cloudsql/README.md):** `setup_workload_identity.sh` already grants this role to `boa-gsa`.
- **Default manifests:** pods run as the `bank-of-anthos` Kubernetes service account. Link it to a Google service account with [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity), then set `WORKLOAD_GSA` to that account when you run the script.

If the role is missing, the services keep running but log permission errors when they try to export spans.

## Limitations

- **In-cluster Postgres metrics are not collected.** The default `accounts-db` and `ledger-db` StatefulSets don't export database metrics. To collect them, add a `postgres_exporter` sidecar and use [Managed Service for Prometheus](https://cloud.google.com/stackdriver/docs/managed-prometheus). Cloud SQL publishes database metrics automatically.
- **The default trace scope applies to everyone** who uses Trace Explorer in the central project.
- **A trace scope can include at most 20 projects**, and a metrics scope at most 375.
- The metrics scope and trace scope commands are in `gcloud beta` or are new GA commands, so their behavior may change.

## Cleanup

1. In the central project's [Trace Explorer](https://console.cloud.google.com/traces/explorer), change the default trace scope away from `boa-central`. A trace scope can't be deleted while it is the default.

2. Remove the remaining resources:

```
gcloud logging sinks delete boa-to-central --project=$PROJECT_ID
gcloud logging sinks update _Default --project=$PROJECT_ID --remove-exclusions=boa-routed-to-central  # if EXCLUDE_FROM_SOURCE=true
gcloud beta monitoring metrics-scopes delete \
  locations/global/metricsScopes/$CENTRAL_PROJECT_ID/projects/$PROJECT_ID
gcloud observability trace-scopes delete \
  projects/$CENTRAL_PROJECT_ID/locations/global/traceScopes/boa-central
gcloud logging buckets delete central-logs --location=global --project=$CENTRAL_PROJECT_ID
```
