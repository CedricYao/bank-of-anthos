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

# Routes Bank of Anthos logs, metrics and traces from one or more source
# projects into a central observability project (CENTRAL_PROJECT_ID).
#
#   Logs:    log sink in each source project -> log bucket in CENTRAL_PROJECT_ID (copied)
#   Metrics: each source project added to CENTRAL_PROJECT_ID's metrics scope (queried in place)
#   Traces:  each source project added to CENTRAL_PROJECT_ID's trace scope (queried in place)
#
# Required env vars:
#   PROJECT_ID           project running the GKE cluster (and Cloud SQL, if used)
#   CENTRAL_PROJECT_ID   central observability project
#
# Optional env vars:
#   EXTRA_PROJECT_IDS    space-separated additional source projects, e.g. a separate
#                        Cloud SQL project, whose logs/metrics/traces are also routed
#   LOG_BUCKET           destination log bucket name    (default: central-logs)
#   LOG_BUCKET_LOCATION  destination log bucket region  (default: global)
#   LOG_RETENTION_DAYS   retention on the bucket        (default: 30)
#   SINK_NAME            sink name in each source project (default: boa-to-central)
#   TRACE_SCOPE          trace scope ID in CENTRAL_PROJECT_ID (default: boa-central)
#   EXCLUDE_FROM_SOURCE  "true" to stop storing the routed logs in the source projects'
#                        _Default buckets, so you don't pay twice (default: false)
#   EXCLUSION_NAME       name of that exclusion (default: boa-routed-to-central)
#   WORKLOAD_GSA         Google service account the Bank of Anthos pods use, e.g.
#                        boa-gsa@${PROJECT_ID}.iam.gserviceaccount.com. If set, it is
#                        granted the roles needed to write traces and metrics in PROJECT_ID.

set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID to the Bank of Anthos app project}"
: "${CENTRAL_PROJECT_ID:?Set CENTRAL_PROJECT_ID to the central observability project}"

EXTRA_PROJECT_IDS="${EXTRA_PROJECT_IDS:-}"
LOG_BUCKET="${LOG_BUCKET:-central-logs}"
LOG_BUCKET_LOCATION="${LOG_BUCKET_LOCATION:-global}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
SINK_NAME="${SINK_NAME:-boa-to-central}"
TRACE_SCOPE="${TRACE_SCOPE:-boa-central}"
EXCLUDE_FROM_SOURCE="${EXCLUDE_FROM_SOURCE:-false}"
EXCLUSION_NAME="${EXCLUSION_NAME:-boa-routed-to-central}"
WORKLOAD_GSA="${WORKLOAD_GSA:-}"

SOURCE_PROJECT_IDS="${PROJECT_ID} ${EXTRA_PROJECT_IDS}"

# GKE cluster/workload logs, Cloud SQL logs (if used) and audit logs.
LOG_FILTER='resource.type=("k8s_container" OR "k8s_pod" OR "k8s_node" OR "k8s_cluster" OR "gke_cluster" OR "cloudsql_database") OR logName:"cloudaudit.googleapis.com"'

SINK_DESTINATION="logging.googleapis.com/projects/${CENTRAL_PROJECT_ID}/locations/${LOG_BUCKET_LOCATION}/buckets/${LOG_BUCKET}"

echo "☁️ Enabling APIs..."
for P in ${SOURCE_PROJECT_IDS}; do
  gcloud services enable logging.googleapis.com monitoring.googleapis.com cloudtrace.googleapis.com \
    --project="${P}"
done
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

for P in ${SOURCE_PROJECT_IDS}; do
  if gcloud logging sinks describe "${SINK_NAME}" --project="${P}" > /dev/null 2>&1; then
    echo "📜 Updating log sink ${SINK_NAME} in ${P}..."
    gcloud logging sinks update "${SINK_NAME}" "${SINK_DESTINATION}" \
      --log-filter="${LOG_FILTER}" --project="${P}"
  else
    echo "📜 Creating log sink ${SINK_NAME} in ${P}..."
    gcloud logging sinks create "${SINK_NAME}" "${SINK_DESTINATION}" \
      --log-filter="${LOG_FILTER}" --project="${P}"
  fi

  echo "📜 Granting ${P}'s sink writer identity access to ${CENTRAL_PROJECT_ID}..."
  WRITER_IDENTITY=$(gcloud logging sinks describe "${SINK_NAME}" \
    --project="${P}" --format='value(writerIdentity)')
  gcloud projects add-iam-policy-binding "${CENTRAL_PROJECT_ID}" \
    --member="${WRITER_IDENTITY}" --role=roles/logging.bucketWriter \
    --condition=None --quiet > /dev/null

  if [ "${EXCLUDE_FROM_SOURCE}" = "true" ]; then
    echo "📜 Excluding routed logs from ${P}'s _Default bucket..."
    gcloud logging sinks update _Default --project="${P}" \
      --remove-exclusions="${EXCLUSION_NAME}" > /dev/null 2>&1 || true
    gcloud logging sinks update _Default --project="${P}" \
      --add-exclusion="name=${EXCLUSION_NAME},filter=${LOG_FILTER}"
  fi
done

### Metrics ###

for P in ${SOURCE_PROJECT_IDS}; do
  echo "📈 Adding ${P} to ${CENTRAL_PROJECT_ID}'s metrics scope..."
  if ! OUTPUT=$(gcloud beta monitoring metrics-scopes create "projects/${P}" \
      --project="${CENTRAL_PROJECT_ID}" 2>&1); then
    if echo "${OUTPUT}" | grep -qi "already exists"; then
      echo "📈 ${P} is already in the metrics scope"
    else
      echo "${OUTPUT}" >&2
      exit 1
    fi
  fi
done

### Traces ###

TRACE_SCOPE_NAME="projects/${CENTRAL_PROJECT_ID}/locations/global/traceScopes/${TRACE_SCOPE}"
TRACE_RESOURCES="projects/${CENTRAL_PROJECT_ID}"
for P in ${SOURCE_PROJECT_IDS}; do
  TRACE_RESOURCES="${TRACE_RESOURCES},projects/${P}"
done

if gcloud observability trace-scopes describe "${TRACE_SCOPE_NAME}" > /dev/null 2>&1; then
  echo "🔍 Updating trace scope ${TRACE_SCOPE}..."
  gcloud observability trace-scopes update "${TRACE_SCOPE_NAME}" \
    --resource-names="${TRACE_RESOURCES}"
else
  echo "🔍 Creating trace scope ${TRACE_SCOPE}..."
  gcloud observability trace-scopes create "${TRACE_SCOPE_NAME}" \
    --resource-names="${TRACE_RESOURCES}" \
    --description="Bank of Anthos traces from ${SOURCE_PROJECT_IDS}"
fi

echo "🔍 Making ${TRACE_SCOPE} the default trace scope for ${CENTRAL_PROJECT_ID}..."
gcloud observability scopes update "projects/${CENTRAL_PROJECT_ID}/locations/global/scopes/_Default" \
  --trace-scope="${TRACE_SCOPE_NAME}"

echo "⭐️ Done."
echo "   Logs:    https://console.cloud.google.com/logs/query?project=${CENTRAL_PROJECT_ID}"
echo "            (refine scope -> storage -> ${LOG_BUCKET})"
echo "   Metrics: https://console.cloud.google.com/monitoring?project=${CENTRAL_PROJECT_ID}"
echo "   Traces:  https://console.cloud.google.com/traces/explorer?project=${CENTRAL_PROJECT_ID}"
