#!/usr/bin/env bash
set -euo pipefail

# Validates a certsuite test bundle directory for correctness.
#
# The test bundle is responsible for deploying operator operands and
# verifying the operator is properly deployed. It does NOT contain
# certsuite configuration (that is managed separately).
#
# Usage:
#   ./validate-test-bundle.sh /path/to/certsuite-test-bundle

BUNDLE_DIR="${1:-}"
ERRORS=0
WARNINGS=0

if [[ -z "${BUNDLE_DIR}" ]]; then
  echo "Usage: $(basename "$0") <bundle-directory>"
  exit 1
fi

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo "  WARN: $1"; WARNINGS=$((WARNINGS + 1)); }

echo "Validating test bundle: ${BUNDLE_DIR}"
echo "============================================"

# ── Structure checks ──────────────────────────────────────────────────
echo ""
echo "Structure:"

if [[ ! -d "${BUNDLE_DIR}" ]]; then
  fail "Directory does not exist: ${BUNDLE_DIR}"
  echo ""
  echo "RESULT: ${ERRORS} error(s), ${WARNINGS} warning(s)"
  exit 1
fi

if [[ -f "${BUNDLE_DIR}/certsuite-test-bundle.yaml" ]]; then
  pass "certsuite-test-bundle.yaml exists"
else
  fail "certsuite-test-bundle.yaml not found"
fi

if [[ -d "${BUNDLE_DIR}/operands" ]]; then
  MANIFEST_COUNT=$(find "${BUNDLE_DIR}/operands" -name "*.yaml" -o -name "*.yml" 2>/dev/null | wc -l | tr -d ' ')
  if [[ ${MANIFEST_COUNT} -gt 0 ]]; then
    pass "operands/ contains ${MANIFEST_COUNT} manifest(s)"
  else
    fail "operands/ directory is empty (no .yaml/.yml files)"
  fi
else
  fail "operands/ directory not found"
fi

# ── Bundle manifest checks ────────────────────────────────────────────
echo ""
echo "Bundle manifest:"

if [[ -f "${BUNDLE_DIR}/certsuite-test-bundle.yaml" ]]; then
  if grep -q "kind: TestBundle" "${BUNDLE_DIR}/certsuite-test-bundle.yaml"; then
    pass "kind: TestBundle"
  else
    fail "Missing 'kind: TestBundle'"
  fi

  if grep -q "name:" "${BUNDLE_DIR}/certsuite-test-bundle.yaml" | head -1; then
    pass "metadata.name is set"
  fi

  if grep -q "readiness:" "${BUNDLE_DIR}/certsuite-test-bundle.yaml"; then
    pass "readiness checks defined"
  else
    warn "No readiness checks defined (pipeline may not wait for operands)"
  fi

  # Validate installMode
  INSTALL_MODE=$(grep -E '^\s*installMode:' "${BUNDLE_DIR}/certsuite-test-bundle.yaml" \
    | head -1 | awk '{print $2}' | tr -d '"' || echo "")
  if [[ -n "${INSTALL_MODE}" ]]; then
    case "${INSTALL_MODE}" in
      AllNamespaces|OwnNamespace|SingleNamespace|MultiNamespace)
        pass "installMode: ${INSTALL_MODE}"
        ;;
      *)
        fail "installMode '${INSTALL_MODE}' is not valid. Use AllNamespaces, OwnNamespace, SingleNamespace, or MultiNamespace."
        ;;
    esac

    NAMESPACE_VAL=$(grep -E '^\s*namespace:' "${BUNDLE_DIR}/certsuite-test-bundle.yaml" \
      | head -1 | awk '{print $2}' | tr -d '"' || echo "")
    if [[ "${INSTALL_MODE}" == "SingleNamespace" || "${INSTALL_MODE}" == "MultiNamespace" ]]; then
      if [[ -z "${NAMESPACE_VAL}" ]]; then
        warn "installMode=${INSTALL_MODE} but no namespace is set. Pipeline will fail without a target namespace."
      fi
    fi
  fi

  # Validate discoveryLabels.resources[].kind
  if grep -q "discoveryLabels:" "${BUNDLE_DIR}/certsuite-test-bundle.yaml"; then
    IN_DISCOVERY=false
    IN_RESOURCES=false
    while IFS= read -r line; do
      if echo "${line}" | grep -q "discoveryLabels:"; then
        IN_DISCOVERY=true
        continue
      fi
      if ${IN_DISCOVERY} && echo "${line}" | grep -q "resources:"; then
        IN_RESOURCES=true
        continue
      fi
      if ${IN_RESOURCES}; then
        if echo "${line}" | grep -qE '^\s+- kind:'; then
          KIND=$(echo "${line}" | awk '{print $NF}' | tr -d '"')
          case "${KIND}" in
            Deployment|DaemonSet|StatefulSet)
              pass "discoveryLabels resource kind: ${KIND}"
              ;;
            *)
              fail "discoveryLabels resource kind '${KIND}' is not valid. Use Deployment, DaemonSet, or StatefulSet."
              ;;
          esac
        elif echo "${line}" | grep -qE '^[[:space:]]*[a-zA-Z]' && ! echo "${line}" | grep -qE '^\s+-'; then
          IN_RESOURCES=false
          IN_DISCOVERY=false
        fi
      fi
    done < "${BUNDLE_DIR}/certsuite-test-bundle.yaml"
  fi

  if grep -q "csvPatches:" "${BUNDLE_DIR}/certsuite-test-bundle.yaml"; then
    pass "csvPatches declared"
  elif [[ -d "${BUNDLE_DIR}/csv-patches" ]]; then
    pass "csv-patches/ directory present (auto-discovered)"
  fi
fi

# ── CSV patch checks ──────────────────────────────────────────────────
echo ""
echo "CSV patches (optional):"

if [[ -d "${BUNDLE_DIR}/csv-patches" ]]; then
  PATCH_COUNT=$(find "${BUNDLE_DIR}/csv-patches" \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" \) -type f 2>/dev/null | wc -l | tr -d ' ')
  if [[ ${PATCH_COUNT} -gt 0 ]]; then
    pass "csv-patches/ contains ${PATCH_COUNT} patch file(s)"
    for f in "${BUNDLE_DIR}/csv-patches"/*.json; do
      [[ -f "${f}" ]] || continue
      if command -v python3 &>/dev/null; then
        if python3 -c "import json; data=json.load(open('${f}')); assert isinstance(data, list)" 2>/dev/null; then
          pass "$(basename "${f}"): JSON6902 list"
        else
          fail "$(basename "${f}"): expected a JSON6902 array"
        fi
      fi
    done
  else
    warn "csv-patches/ exists but is empty"
  fi
else
  pass "no csv-patches/ (OK — optional)"
fi

# ── Operand manifest checks ───────────────────────────────────────────
echo ""
echo "Operand manifests:"

if [[ -d "${BUNDLE_DIR}/operands" ]]; then
  HAS_CR=false

  for f in "${BUNDLE_DIR}/operands"/*.yaml "${BUNDLE_DIR}/operands"/*.yml; do
    [[ -f "${f}" ]] || continue
    BASENAME=$(basename "${f}")
    HAS_CR=true

    # Validate YAML syntax
    if command -v python3 &>/dev/null; then
      if ! python3 -c "import yaml; yaml.safe_load(open('${f}'))" 2>/dev/null; then
        warn "${BASENAME}: invalid YAML syntax"
      fi
    fi
  done

  if ${HAS_CR}; then
    pass "Operand manifests found"
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────
echo ""
echo "============================================"
if [[ ${ERRORS} -eq 0 ]]; then
  echo "RESULT: PASS (${WARNINGS} warning(s))"
  exit 0
else
  echo "RESULT: FAIL (${ERRORS} error(s), ${WARNINGS} warning(s))"
  exit 1
fi
