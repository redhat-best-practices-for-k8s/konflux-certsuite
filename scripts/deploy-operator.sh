#!/usr/bin/env bash
set -euo pipefail

# Deploys an OLM-managed operator on the shared cluster.
# Reads install config from the certsuite test bundle via resolve-bundle-config.sh.

FBC_FRAGMENT="${FBC_FRAGMENT:?FBC_FRAGMENT is required}"
BUNDLE_IMAGE="${BUNDLE_IMAGE:?BUNDLE_IMAGE is required}"
PACKAGE_NAME="${PACKAGE_NAME:?PACKAGE_NAME is required}"
CHANNEL_NAME="${CHANNEL_NAME:?CHANNEL_NAME is required}"
BUNDLE_DIR="${BUNDLE_DIR:?BUNDLE_DIR is required}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/workspace/konflux-artifacts}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(dirname "$0")}"

mkdir -p "${ARTIFACT_DIR}"

echo "[$(date -u +%FT%T.%3NZ)] Deploying operator: package=${PACKAGE_NAME}, channel=${CHANNEL_NAME}"
echo "[$(date -u +%FT%T.%3NZ)] FBC Fragment: ${FBC_FRAGMENT}"
echo "[$(date -u +%FT%T.%3NZ)] Bundle Image: ${BUNDLE_IMAGE}"

oc whoami || { echo "ERROR: Failed to connect to cluster"; exit 1; }

if ! bundle_render_out=$(opm render "${BUNDLE_IMAGE}"); then
  echo "ERROR: Failed to render the bundle image" >&2
  exit 1
fi

# Extract CSV fallback metadata for the resolver
CSV_SUGGESTED_NS=$(echo "${bundle_render_out}" | \
  jq -r 'select(.schema == "olm.bundle") | .properties[]? |
  select(.type == "olm.bundle.object") | .value.data' 2>/dev/null | \
  base64 -d 2>/dev/null | \
  jq -r 'select(.kind == "ClusterServiceVersion") |
  .metadata.annotations["operatorframework.io/suggested-namespace"] // empty' 2>/dev/null | \
  head -1 || echo "")

CSV_INSTALL_MODES=$(echo "${bundle_render_out}" | jq -r '
  select(.schema == "olm.bundle") | .properties[]? |
  select(.type == "olm.bundle.object") | .value.data' 2>/dev/null | \
  base64 -d 2>/dev/null | jq -r '
  select(.kind == "ClusterServiceVersion") |
  .spec.installModes[]? | select(.supported == true) | .type' 2>/dev/null || echo "")

export CSV_SUGGESTED_NS CSV_INSTALL_MODES
source "${SCRIPTS_DIR}/resolve-bundle-config.sh"

INSTALL_NAMESPACE="${BUNDLE_NAMESPACE}"
if [[ -z "${INSTALL_NAMESPACE}" ]]; then
  echo "[$(date -u +%FT%T.%3NZ)] No namespace configured, creating a new one"
  INSTALL_NAMESPACE=$(oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  generateName: oo-
EOF
  )
elif ! oc get namespace "${INSTALL_NAMESPACE}" &>/dev/null; then
  echo "[$(date -u +%FT%T.%3NZ)] Creating namespace '${INSTALL_NAMESPACE}'"
  oc create namespace "${INSTALL_NAMESPACE}"
fi

echo "[$(date -u +%FT%T.%3NZ)] Using install namespace: ${INSTALL_NAMESPACE}"
echo -n "${INSTALL_NAMESPACE}" > /workspace/install-namespace

if [[ "${BUNDLE_INSTALL_MODE}" == "OwnNamespace" && -z "${OG_TARGET_NS}" ]]; then
  OG_TARGET_NS="${INSTALL_NAMESPACE}"
fi

# Create OperatorGroup (mode-aware from resolver)
OPERATORGROUP=$(oc -n "${INSTALL_NAMESPACE}" get operatorgroup -o jsonpath="{.items[*].metadata.name}" 2>/dev/null || true)

if [[ $(echo "${OPERATORGROUP}" | wc -w) -gt 1 ]]; then
  echo "ERROR: Multiple OperatorGroups in namespace '${INSTALL_NAMESPACE}'" >&2
  exit 1
elif [[ -n "${OPERATORGROUP}" ]]; then
  OG_OPERATION=apply
  OG_NAMESTANZA="name: ${OPERATORGROUP}"
else
  OG_OPERATION=create
  OG_NAMESTANZA="generateName: oo-"
fi

OG_SPEC=""
if [[ -n "${OG_TARGET_NS}" ]]; then
  OG_SPEC="targetNamespaces:
    - ${OG_TARGET_NS}"
fi

OPERATORGROUP=$(oc ${OG_OPERATION} -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  ${OG_NAMESTANZA}
  namespace: ${INSTALL_NAMESPACE}
spec:
  ${OG_SPEC}
EOF
)
echo "[$(date -u +%FT%T.%3NZ)] OperatorGroup: ${OPERATORGROUP}"

# Create CatalogSource
CATSRC=$(oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  generateName: oo-
  namespace: ${INSTALL_NAMESPACE}
spec:
  sourceType: grpc
  image: ${FBC_FRAGMENT}
  displayName: "Certsuite Test Catalog"
  publisher: "konflux-certsuite"
EOF
)
echo "[$(date -u +%FT%T.%3NZ)] CatalogSource: ${CATSRC}"

echo "[$(date -u +%FT%T.%3NZ)] Waiting for CatalogSource to be ready..."
for i in $(seq 1 60); do
  STATE=$(oc get catalogsource "${CATSRC}" -n "${INSTALL_NAMESPACE}" \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
  if [[ "${STATE}" == "READY" ]]; then
    echo "[$(date -u +%FT%T.%3NZ)] CatalogSource is ready"
    break
  fi
  if [[ ${i} -eq 60 ]]; then
    echo "ERROR: CatalogSource did not become ready" >&2
    oc get catalogsource "${CATSRC}" -n "${INSTALL_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/catalogsource-${CATSRC}.yaml"
    exit 1
  fi
  sleep 10
done

DEPLOYMENT_START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "[$(date -u +%FT%T.%3NZ)] Deployment start time: ${DEPLOYMENT_START_TIME}"

BUNDLE_NAME=$(echo "${bundle_render_out}" | \
  jq -r 'select(.schema == "olm.bundle") | .name' 2>/dev/null | head -1)

SUB=$(oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  generateName: oo-
  namespace: ${INSTALL_NAMESPACE}
spec:
  channel: ${CHANNEL_NAME}
  installPlanApproval: Automatic
  name: ${PACKAGE_NAME}
  source: ${CATSRC}
  sourceNamespace: ${INSTALL_NAMESPACE}
  startingCSV: ${BUNDLE_NAME}
EOF
)
echo "[$(date -u +%FT%T.%3NZ)] Subscription: ${SUB}"

echo "[$(date -u +%FT%T.%3NZ)] Waiting for CSV to become ready..."
for i in $(seq 1 90); do
  CSV=$(oc get subscription "${SUB}" -n "${INSTALL_NAMESPACE}" \
    -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")

  if [[ -n "${CSV}" ]]; then
    PHASE=$(oc get csv "${CSV}" -n "${INSTALL_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "${PHASE}" == "Succeeded" ]]; then
      echo "[$(date -u +%FT%T.%3NZ)] CSV '${CSV}' is ready (phase: Succeeded)"

      echo -n "${CATSRC}" > /workspace/catalogsource-name
      echo -n "${SUB}" > /workspace/subscription-name
      echo -n "${CSV}" > /workspace/csv-name
      echo -n "${OPERATORGROUP}" > /workspace/operatorgroup-name

      # Apply discovery labels from bundle config
      LABEL_KEY="${DISCOVERY_OPERATOR_LABEL%%=*}"
      LABEL_VAL="${DISCOVERY_OPERATOR_LABEL#*=}"
      oc label csv "${CSV}" -n "${INSTALL_NAMESPACE}" \
        "${LABEL_KEY}=${LABEL_VAL}" --overwrite 2>&1

      POD_LABEL_KEY="${DISCOVERY_POD_LABEL%%=*}"
      POD_LABEL_VAL="${DISCOVERY_POD_LABEL#*=}"
      for RESOURCE_KIND in ${DISCOVERY_RESOURCE_KINDS}; do
        LOWER_KIND=$(echo "${RESOURCE_KIND}" | tr '[:upper:]' '[:lower:]')
        NAMES=$(oc get "${LOWER_KIND}" -n "${INSTALL_NAMESPACE}" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        for RNAME in ${NAMES}; do
          echo "[$(date -u +%FT%T.%3NZ)] Patching ${RESOURCE_KIND} ${RNAME} with discovery label..."
          oc patch "${LOWER_KIND}" "${RNAME}" -n "${INSTALL_NAMESPACE}" --type=merge \
            -p "{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"${POD_LABEL_KEY}\":\"${POD_LABEL_VAL}\"}}}}}" 2>&1
          oc rollout status "${LOWER_KIND}/${RNAME}" -n "${INSTALL_NAMESPACE}" --timeout=120s 2>&1 || true
        done
      done

      exit 0
    fi
    echo "[$(date -u +%FT%T.%3NZ)] CSV '${CSV}' phase: ${PHASE}"
  fi

  sleep 10
done

echo "[$(date -u +%FT%T.%3NZ)] ERROR: Timed out waiting for CSV to become ready"

oc get subscription "${SUB}" -n "${INSTALL_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/subscription-${SUB}.yaml" 2>/dev/null || true
oc get catalogsource "${CATSRC}" -n "${INSTALL_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/catalogsource-${CATSRC}.yaml" 2>/dev/null || true
if [[ -n "${CSV:-}" ]]; then
  oc get csv "${CSV}" -n "${INSTALL_NAMESPACE}" -o yaml > "${ARTIFACT_DIR}/csv-${CSV}.yaml" 2>/dev/null || true
fi

exit 1
