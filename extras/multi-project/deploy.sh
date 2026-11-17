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

# Deploys Bank of Anthos across three projects:
#
#   APP_PROJECT_ID      GKE Autopilot cluster running Bank of Anthos
#   DB_PROJECT_ID       Cloud SQL for PostgreSQL instance (accounts-db + ledger-db)
#   CENTRAL_PROJECT_ID  central logs, metrics and traces
#
# Every Google Cloud resource and the Kubernetes namespace/service account are
# named with PREFIX. Safe to re-run: existing resources are reused.

set -euo pipefail

APP_PROJECT_ID="${APP_PROJECT_ID:-cloud-assist-fde-2}"
DB_PROJECT_ID="${DB_PROJECT_ID:-cloud-assist-fde-1}"
CENTRAL_PROJECT_ID="${CENTRAL_PROJECT_ID:-cloud-assist-fde-3}"
REGION="${REGION:-us-east4}"
PREFIX="${PREFIX:-cedric-}"
# "true" grants the workload service account roles/cloudtrace.agent and
# roles/monitoring.metricWriter so app traces and custom metrics are exported.
GRANT_TELEMETRY_ROLES="${GRANT_TELEMETRY_ROLES:-false}"

NETWORK="${PREFIX}boa-vpc"
SUBNET="${PREFIX}boa-subnet"
SUBNET_RANGE="10.10.0.0/20"
CLUSTER="${PREFIX}bank-of-anthos"
NODE_GSA_NAME="${PREFIX}boa-node"
WORKLOAD_GSA_NAME="${PREFIX}boa-gsa"
NAMESPACE="${PREFIX}bank-of-anthos"
KSA_NAME="${PREFIX}boa-ksa"
INSTANCE_NAME="${PREFIX}bank-of-anthos-db"
DB_USER="admin"

NODE_GSA="${NODE_GSA_NAME}@${APP_PROJECT_ID}.iam.gserviceaccount.com"
WORKLOAD_GSA="${WORKLOAD_GSA_NAME}@${APP_PROJECT_ID}.iam.gserviceaccount.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUDSQL_DIR="${SCRIPT_DIR}/../cloudsql"

for CMD in gcloud kubectl openssl; do
  command -v "${CMD}" > /dev/null || { echo "❌ ${CMD} is required" >&2; exit 1; }
done

### APIs ###

echo "☁️ Enabling APIs..."
gcloud services enable compute.googleapis.com container.googleapis.com iam.googleapis.com \
  sqladmin.googleapis.com --project="${APP_PROJECT_ID}"
gcloud services enable sqladmin.googleapis.com --project="${DB_PROJECT_ID}"

### Network (app project) ###

if gcloud compute networks describe "${NETWORK}" --project="${APP_PROJECT_ID}" > /dev/null 2>&1; then
  echo "🌐 Network ${NETWORK} already exists"
else
  echo "🌐 Creating network ${NETWORK}..."
  gcloud compute networks create "${NETWORK}" --subnet-mode=custom --project="${APP_PROJECT_ID}"
fi

if gcloud compute networks subnets describe "${SUBNET}" --region="${REGION}" \
    --project="${APP_PROJECT_ID}" > /dev/null 2>&1; then
  echo "🌐 Subnet ${SUBNET} already exists"
else
  echo "🌐 Creating subnet ${SUBNET}..."
  gcloud compute networks subnets create "${SUBNET}" --network="${NETWORK}" \
    --region="${REGION}" --range="${SUBNET_RANGE}" --enable-private-ip-google-access \
    --project="${APP_PROJECT_ID}"
fi

### Service accounts (app project) ###

for GSA_NAME in "${NODE_GSA_NAME}" "${WORKLOAD_GSA_NAME}"; do
  if gcloud iam service-accounts describe "${GSA_NAME}@${APP_PROJECT_ID}.iam.gserviceaccount.com" \
      --project="${APP_PROJECT_ID}" > /dev/null 2>&1; then
    echo "✅ Service account ${GSA_NAME} already exists"
  else
    echo "✅ Creating service account ${GSA_NAME}..."
    gcloud iam service-accounts create "${GSA_NAME}" --project="${APP_PROJECT_ID}"
  fi
done

echo "✅ Granting the node service account the GKE default node role..."
gcloud projects add-iam-policy-binding "${APP_PROJECT_ID}" \
  --member="serviceAccount:${NODE_GSA}" --role=roles/container.defaultNodeServiceAccount \
  --condition=None --quiet > /dev/null

### GKE Autopilot cluster (app project) ###

if gcloud container clusters describe "${CLUSTER}" --region="${REGION}" \
    --project="${APP_PROJECT_ID}" > /dev/null 2>&1; then
  echo "☸️ Cluster ${CLUSTER} already exists"
else
  echo "☸️ Creating Autopilot cluster ${CLUSTER} (this takes several minutes)..."
  gcloud container clusters create-auto "${CLUSTER}" \
    --region="${REGION}" --network="${NETWORK}" --subnetwork="${SUBNET}" \
    --service-account="${NODE_GSA}" --labels=dev-tutorial=bank-of-anthos \
    --project="${APP_PROJECT_ID}"
fi

gcloud container clusters get-credentials "${CLUSTER}" --region="${REGION}" \
  --project="${APP_PROJECT_ID}"

### Workload Identity ###

echo "✅ Creating namespace ${NAMESPACE} and service account ${KSA_NAME}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount "${KSA_NAME}" -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
kubectl annotate serviceaccount "${KSA_NAME}" -n "${NAMESPACE}" --overwrite \
  iam.gke.io/gcp-service-account="${WORKLOAD_GSA}"

echo "✅ Letting ${KSA_NAME} act as ${WORKLOAD_GSA_NAME}..."
gcloud iam service-accounts add-iam-policy-binding "${WORKLOAD_GSA}" \
  --role=roles/iam.workloadIdentityUser \
  --member="serviceAccount:${APP_PROJECT_ID}.svc.id.goog[${NAMESPACE}/${KSA_NAME}]" \
  --project="${APP_PROJECT_ID}" --condition=None --quiet > /dev/null

echo "✅ Granting ${WORKLOAD_GSA_NAME} Cloud SQL client access in ${DB_PROJECT_ID}..."
gcloud projects add-iam-policy-binding "${DB_PROJECT_ID}" \
  --member="serviceAccount:${WORKLOAD_GSA}" --role=roles/cloudsql.client \
  --condition=None --quiet > /dev/null

### Cloud SQL (DB project) ###

if gcloud sql instances describe "${INSTANCE_NAME}" --project="${DB_PROJECT_ID}" > /dev/null 2>&1; then
  echo "🗄️ Cloud SQL instance ${INSTANCE_NAME} already exists"
else
  echo "🗄️ Creating Cloud SQL instance ${INSTANCE_NAME} (this takes several minutes)..."
  gcloud sql instances create "${INSTANCE_NAME}" \
    --database-version=POSTGRES_14 --edition=enterprise --tier=db-custom-1-3840 \
    --region="${REGION}" --project="${DB_PROJECT_ID}"
fi

for DB in accounts-db ledger-db; do
  if gcloud sql databases describe "${DB}" --instance="${INSTANCE_NAME}" \
      --project="${DB_PROJECT_ID}" > /dev/null 2>&1; then
    echo "🗄️ Database ${DB} already exists"
  else
    echo "🗄️ Creating database ${DB}..."
    gcloud sql databases create "${DB}" --instance="${INSTANCE_NAME}" --project="${DB_PROJECT_ID}"
  fi
done

# Reuse the password from a previous run so running pods keep working.
DB_PASSWORD=$(kubectl get secret cloud-sql-admin -n "${NAMESPACE}" \
  -o jsonpath='{.data.password}' 2> /dev/null | base64 --decode || true)
if [ -z "${DB_PASSWORD}" ]; then
  echo "🔑 Generating a database password..."
  DB_PASSWORD=$(openssl rand -hex 24)
fi

DB_USERS=$(gcloud sql users list --instance="${INSTANCE_NAME}" --project="${DB_PROJECT_ID}" \
  --format='value(name)')
if echo "${DB_USERS}" | grep -qx "${DB_USER}"; then
  echo "🔑 Setting password for database user ${DB_USER}..."
  gcloud sql users set-password "${DB_USER}" --instance="${INSTANCE_NAME}" \
    --password="${DB_PASSWORD}" --project="${DB_PROJECT_ID}"
else
  echo "🔑 Creating database user ${DB_USER}..."
  gcloud sql users create "${DB_USER}" --instance="${INSTANCE_NAME}" \
    --password="${DB_PASSWORD}" --project="${DB_PROJECT_ID}"
fi

INSTANCE_CONNECTION_NAME=$(gcloud sql instances describe "${INSTANCE_NAME}" \
  --project="${DB_PROJECT_ID}" --format='value(connectionName)')

kubectl create secret generic cloud-sql-admin -n "${NAMESPACE}" \
  --from-literal=username="${DB_USER}" --from-literal=password="${DB_PASSWORD}" \
  --from-literal=connectionName="${INSTANCE_CONNECTION_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

### Bank of Anthos ###

# Render the Cloud SQL manifests with the prefixed service account and the
# generated password. The rendered copy is deleted on exit.
RENDER_DIR=$(mktemp -d)
trap 'rm -rf "${RENDER_DIR}"' EXIT
mkdir -p "${RENDER_DIR}/kubernetes-manifests" "${RENDER_DIR}/populate-jobs"
for SRC in "${CLOUDSQL_DIR}"/kubernetes-manifests/*.yaml "${CLOUDSQL_DIR}"/populate-jobs/*.yaml; do
  DEST="${RENDER_DIR}/$(basename "$(dirname "${SRC}")")/$(basename "${SRC}")"
  sed -e "s/serviceAccountName: boa-ksa/serviceAccountName: ${KSA_NAME}/" \
      -e "s#postgresql://admin:admin@#postgresql://${DB_USER}:${DB_PASSWORD}@#" \
      -e "s/POSTGRES_PASSWORD: admin/POSTGRES_PASSWORD: ${DB_PASSWORD}/" \
      -e "s/SPRING_DATASOURCE_PASSWORD: admin/SPRING_DATASOURCE_PASSWORD: ${DB_PASSWORD}/" \
      "${SRC}" > "${DEST}"
done

echo "🏦 Deploying Bank of Anthos to ${NAMESPACE}..."
kubectl apply -n "${NAMESPACE}" -f "${RENDER_DIR}/kubernetes-manifests/config.yaml"
kubectl apply -n "${NAMESPACE}" -f "${RENDER_DIR}/populate-jobs"
kubectl apply -n "${NAMESPACE}" -f "${RENDER_DIR}/kubernetes-manifests"

### Central observability ###

TELEMETRY_GSA=""
if [ "${GRANT_TELEMETRY_ROLES}" = "true" ]; then
  TELEMETRY_GSA="${WORKLOAD_GSA}"
fi

WORKLOAD_GSA="${TELEMETRY_GSA}" \
PROJECT_ID="${APP_PROJECT_ID}" \
EXTRA_PROJECT_IDS="${DB_PROJECT_ID}" \
CENTRAL_PROJECT_ID="${CENTRAL_PROJECT_ID}" \
LOG_BUCKET="${PREFIX}central-logs" \
SINK_NAME="${PREFIX}boa-to-central" \
TRACE_SCOPE="${PREFIX}boa-central" \
EXCLUSION_NAME="${PREFIX}boa-routed-to-central" \
  "${SCRIPT_DIR}/../central-observability/setup_central_observability.sh"

echo "⭐️ Done. Waiting for the frontend's external IP:"
echo "   kubectl get service frontend -n ${NAMESPACE} --watch"
