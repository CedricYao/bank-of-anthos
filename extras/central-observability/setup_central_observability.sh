#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Routes Bank of Anthos logs, metrics and traces from the app project
# (PROJECT_ID) into a central observability project (CENTRAL_PROJECT_ID).
#
#   Logs:    log sink in PROJECT_ID -> log bucket in CENTRAL_PROJECT_ID (copied)
#   Metrics: PROJECT_ID added to CENTRAL_PROJECT_ID's metrics scope (queried in place)
#   Traces:  PROJECT_ID added to CENTRAL_PROJECT_ID's trace scope (queried in place)
#
# Required env vars:
#   PROJECT_ID           project running the GKE cluster (and Cloud SQL, if used)
#   CENTRAL_PROJECT_ID   central observability project
#
# Optional env vars:
#   LOG_BUCKET           destination log bucket name    (default: central-logs)
#   LOG_BUCKET_LOCATION  destination log bucket region  (default: global)
#   LOG_RETENTION_DAYS   retention on the bucket        (default: 30)
#   SINK_NAME            sink name in PROJECT_ID        (default: boa-to-central)
#   EXCLUDE_FROM_SOURCE  "true" to stop storing the routed logs in PROJECT_ID's
#                        _Default bucket, so you don't pay twice (default: false)
#   WORKLOAD_GSA         Google service account the Bank of Anthos pods use, e.g.
#                        boa-gsa@${PROJECT_ID}.iam.gserviceaccount.com. If set, it is
#                        granted the roles needed to write traces and metrics.

set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID to the Bank of Anthos app project}"
: "${CENTRAL_PROJECT_ID:?Set CENTRAL_PROJECT_ID to the central observability project}"

LOG_BUCKET="${LOG_BUCKET:-central-logs}"
LOG_BUCKET_LOCATION="${LOG_BUCKET_LOCATION:-global}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
SINK_NAME="${SINK_NAME:-boa-to-central}"
EXCLUDE_FROM_SOURCE="${EXCLUDE_FROM_SOURCE:-false}"
WORKLOAD_GSA="${WORKLOAD_GSA:-}"
TRACE_SCOPE="boa-central"

# GKE cluster/workload logs, Cloud SQL logs (if used) and audit logs.
LOG_FILTER='resource.type=("k8s_container" OR "k8s_pod" OR "k8s_node" OR "k8s_cluster" OR "gke_cluster" OR "cloudsql_database") OR logName:"cloudaudit.googleapis.com"'

SINK_DESTINATION="logging.googleapis.com/projects/${CENTRAL_PROJECT_ID}/locations/${LOG_BUCKET_LOCATION}/buckets/${LOG_BUCKET}"

echo "☁️ Enabling APIs..."
gcloud services enable logging.googleapis.com monitoring.googleapis.com cloudtrace.googleapis.com \
  --project="${PROJECT_ID}"
gcloud services enable logging.googleapis.com monitoring.googleapis.com cloudtrace.googleapis.com \
  observability.googleapis.com --project="${CENTRAL_PROJECT_ID}"

if [ -n "${WORKLOAD_GSA}" ]; then
  echo "✅ Granting ${WORKLOAD_GSA} permission to write traces and metrics..."
  for ROLE in roles/cloudtrace.agent roles/monitoring.metricWriter; do
    gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
      --member="serviceAccount:${WORKLOAD_GSA}" --role="${ROLE}" \
      --condition=None --quiet > /dev/null
  done
fi

### Logs ###

if gcloud logging buckets describe "${LOG_BUCKET}" --location="${LOG_BUCKET_LOCATION}" \
    --project="${CENTRAL_PROJECT_ID}" > /dev/null 2>&1; then
  echo "📜 Log bucket ${LOG_BUCKET} already exists in ${CENTRAL_PROJECT_ID}"
else
  echo "📜 Creating log bucket ${LOG_BUCKET} in ${CENTRAL_PROJECT_ID}..."
  gcloud logging buckets create "${LOG_BUCKET}" \
    --location="${LOG_BUCKET_LOCATION}" --retention-days="${LOG_RETENTION_DAYS}" \
    --enable-analytics --project="${CENTRAL_PROJECT_ID}"
fi

if gcloud logging sinks describe "${SINK_NAME}" --project="${PROJECT_ID}" > /dev/null 2>&1; then
  echo "📜 Updating log sink ${SINK_NAME} in ${PROJECT_ID}..."
  gcloud logging sinks update "${SINK_NAME}" "${SINK_DESTINATION}" \
    --log-filter="${LOG_FILTER}" --project="${PROJECT_ID}"
else
  echo "📜 Creating log sink ${SINK_NAME} in ${PROJECT_ID}..."
  gcloud logging sinks create "${SINK_NAME}" "${SINK_DESTINATION}" \
    --log-filter="${LOG_FILTER}" --project="${PROJECT_ID}"
fi

echo "📜 Granting the sink's writer identity access to ${CENTRAL_PROJECT_ID}..."
WRITER_IDENTITY=$(gcloud logging sinks describe "${SINK_NAME}" \
  --project="${PROJECT_ID}" --format='value(writerIdentity)')
gcloud projects add-iam-policy-binding "${CENTRAL_PROJECT_ID}" \
  --member="${WRITER_IDENTITY}" --role=roles/logging.bucketWriter \
  --condition=None --quiet > /dev/null

if [ "${EXCLUDE_FROM_SOURCE}" = "true" ]; then
  echo "📜 Excluding routed logs from ${PROJECT_ID}'s _Default bucket..."
  gcloud logging sinks update _Default --project="${PROJECT_ID}" \
    --remove-exclusions=boa-routed-to-central > /dev/null 2>&1 || true
  gcloud logging sinks update _Default --project="${PROJECT_ID}" \
    --add-exclusion="name=boa-routed-to-central,filter=${LOG_FILTER}"
fi

### Metrics ###

echo "📈 Adding ${PROJECT_ID} to ${CENTRAL_PROJECT_ID}'s metrics scope..."
if ! OUTPUT=$(gcloud beta monitoring metrics-scopes create "projects/${PROJECT_ID}" \
    --project="${CENTRAL_PROJECT_ID}" 2>&1); then
  if echo "${OUTPUT}" | grep -qi "already exists"; then
    echo "📈 ${PROJECT_ID} is already in the metrics scope"
  else
    echo "${OUTPUT}" >&2
    exit 1
  fi
fi

### Traces ###

TRACE_SCOPE_NAME="projects/${CENTRAL_PROJECT_ID}/locations/global/traceScopes/${TRACE_SCOPE}"
TRACE_RESOURCES="projects/${CENTRAL_PROJECT_ID},projects/${PROJECT_ID}"

if gcloud observability trace-scopes describe "${TRACE_SCOPE_NAME}" > /dev/null 2>&1; then
  echo "🔍 Updating trace scope ${TRACE_SCOPE}..."
  gcloud observability trace-scopes update "${TRACE_SCOPE_NAME}" \
    --resource-names="${TRACE_RESOURCES}"
else
  echo "🔍 Creating trace scope ${TRACE_SCOPE}..."
  gcloud observability trace-scopes create "${TRACE_SCOPE_NAME}" \
    --resource-names="${TRACE_RESOURCES}" \
    --description="Bank of Anthos traces from ${PROJECT_ID}"
fi

echo "🔍 Making ${TRACE_SCOPE} the default trace scope for ${CENTRAL_PROJECT_ID}..."
gcloud observability scopes update "projects/${CENTRAL_PROJECT_ID}/locations/global/scopes/_Default" \
  --trace-scope="${TRACE_SCOPE_NAME}"

echo "⭐️ Done."
echo "   Logs:    https://console.cloud.google.com/logs/query?project=${CENTRAL_PROJECT_ID}"
echo "            (refine scope -> storage -> ${LOG_BUCKET})"
echo "   Metrics: https://console.cloud.google.com/monitoring?project=${CENTRAL_PROJECT_ID}"
echo "   Traces:  https://console.cloud.google.com/traces/explorer?project=${CENTRAL_PROJECT_ID}"
