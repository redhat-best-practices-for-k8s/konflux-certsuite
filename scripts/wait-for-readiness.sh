#!/usr/bin/env bash
# Waits for readiness checks defined in certsuite-test-bundle.yaml.
#
# Required env / variables before sourcing:
#   BUNDLE_DIR  — path to the fetched test bundle directory
#   TARGET_NS   — namespace to check resources in
#
# Optional env:
#   READINESS_TIMEOUT — seconds to wait per rollout check (default: 300)
#
# Behavior:
#   Deployment/StatefulSet/DaemonSet → oc rollout status
#   Any other kind → presence check (namespace-scoped, then cluster-scoped)
#   No checks defined → wait for all Deployments in TARGET_NS

set -euo pipefail

BUNDLE_FILE="${BUNDLE_DIR}/certsuite-test-bundle.yaml"
READINESS_TIMEOUT="${READINESS_TIMEOUT:-300}"

echo "[$(date -u +%FT%T.%3NZ)] Running readiness and presence checks..."
CHECKS_FAILED=0

CHECKS=""
if [[ -f "${BUNDLE_FILE}" ]]; then
  CHECKS=$(awk '
    /^[[:space:]]*- kind:/ { kind=$NF }
    /^[[:space:]]*name:/ && kind != "" { print kind "/" $NF; kind="" }
  ' "${BUNDLE_FILE}")
fi

if [[ -z "${CHECKS}" ]]; then
  echo "  No explicit checks defined. Waiting for all Deployments..."
  DEPS=$(oc get deployments -n "${TARGET_NS}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  for DEP in ${DEPS}; do
    echo "  Waiting for deployment/${DEP}..."
    oc rollout status "deployment/${DEP}" -n "${TARGET_NS}" \
      --timeout="${READINESS_TIMEOUT}s" || CHECKS_FAILED=$((CHECKS_FAILED + 1))
  done
else
  for CHECK in ${CHECKS}; do
    KIND="${CHECK%%/*}"
    NAME="${CHECK##*/}"
    echo "  Checking ${KIND}/${NAME}..."

    case "${KIND}" in
      Deployment|deployment)
        if ! oc get deployment "${NAME}" -n "${TARGET_NS}" &>/dev/null; then
          echo "    FAIL: Deployment '${NAME}' not found"
          CHECKS_FAILED=$((CHECKS_FAILED + 1))
        else
          echo "    Present. Waiting for rollout..."
          oc rollout status "deployment/${NAME}" -n "${TARGET_NS}" \
            --timeout="${READINESS_TIMEOUT}s" || CHECKS_FAILED=$((CHECKS_FAILED + 1))
        fi
        ;;
      StatefulSet|statefulset)
        if ! oc get statefulset "${NAME}" -n "${TARGET_NS}" &>/dev/null; then
          echo "    FAIL: StatefulSet '${NAME}' not found"
          CHECKS_FAILED=$((CHECKS_FAILED + 1))
        else
          echo "    Present. Waiting for rollout..."
          oc rollout status "statefulset/${NAME}" -n "${TARGET_NS}" \
            --timeout="${READINESS_TIMEOUT}s" || CHECKS_FAILED=$((CHECKS_FAILED + 1))
        fi
        ;;
      DaemonSet|daemonset)
        if ! oc get daemonset "${NAME}" -n "${TARGET_NS}" &>/dev/null; then
          echo "    FAIL: DaemonSet '${NAME}' not found"
          CHECKS_FAILED=$((CHECKS_FAILED + 1))
        else
          echo "    Present. Waiting for rollout..."
          oc rollout status "daemonset/${NAME}" -n "${TARGET_NS}" \
            --timeout="${READINESS_TIMEOUT}s" || CHECKS_FAILED=$((CHECKS_FAILED + 1))
        fi
        ;;
      *)
        LOWER_KIND=$(echo "${KIND}" | tr '[:upper:]' '[:lower:]')
        if oc get "${LOWER_KIND}" "${NAME}" -n "${TARGET_NS}" &>/dev/null; then
          echo "    Present"
        elif oc get "${LOWER_KIND}" "${NAME}" &>/dev/null; then
          echo "    Present (cluster-scoped)"
        else
          echo "    FAIL: ${KIND} '${NAME}' not found"
          CHECKS_FAILED=$((CHECKS_FAILED + 1))
        fi
        ;;
    esac
  done
fi

if [[ ${CHECKS_FAILED} -gt 0 ]]; then
  echo "[$(date -u +%FT%T.%3NZ)] WARNING: ${CHECKS_FAILED} check(s) failed"
fi
