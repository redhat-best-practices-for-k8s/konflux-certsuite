#!/usr/bin/env bash
# Apply optional CSV patches from an operator test bundle.
#
# Usage:
#   CSV_NAME=... INSTALL_NAMESPACE=... BUNDLE_DIR=... ./apply-csv-patches.sh
#
# Patch discovery (first match wins):
#   1. spec.csvPatches[] in certsuite-test-bundle.yaml (relative paths)
#   2. Else all files under csv-patches/ sorted by name
#
# Patch types:
#   - JSON6902: JSON array of {op,path,...} (idempotent remove if path missing)
#   - YAML JSON6902 lists are converted with yq when available
#   - Otherwise treated as strategic-merge via `oc patch --local`
#
# If no patches are found, exits 0 (no-op).

set -euo pipefail

CSV_NAME="${CSV_NAME:?CSV_NAME is required}"
INSTALL_NAMESPACE="${INSTALL_NAMESPACE:?INSTALL_NAMESPACE is required}"
BUNDLE_DIR="${BUNDLE_DIR:?BUNDLE_DIR is required}"

BUNDLE_MANIFEST="${BUNDLE_DIR}/certsuite-test-bundle.yaml"
PATCH_DIR="${BUNDLE_DIR}/csv-patches"

collect_patch_files() {
  if [[ -f "${BUNDLE_MANIFEST}" ]] && command -v yq &>/dev/null; then
    local listed
    listed=$(yq -r '.spec.csvPatches[]? | (.path // .) | select(. != null and . != "")' \
      "${BUNDLE_MANIFEST}" 2>/dev/null || true)
    if [[ -n "${listed}" ]]; then
      while IFS= read -r rel; do
        [[ -z "${rel}" || "${rel}" == "null" ]] && continue
        echo "${BUNDLE_DIR}/${rel}"
      done <<< "${listed}"
      return
    fi
  fi

  if [[ -d "${PATCH_DIR}" ]]; then
    find "${PATCH_DIR}" \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) -type f | sort
  fi
}

# Write JSON6902 ops JSON to stdout. Returns 1 if file is not a JSON6902 list.
json6902_ops() {
  local f="$1" raw
  if [[ "${f}" == *.json ]]; then
    raw=$(cat "${f}")
  elif command -v yq &>/dev/null; then
    raw=$(yq -o=json '.' "${f}")
  else
    return 1
  fi
  echo "${raw}" | python3 -c 'import json,sys; data=json.load(sys.stdin); assert isinstance(data, list); json.dump(data, sys.stdout)'
}

apply_json6902_to_file() {
  local csv_json_file="$1" ops_file="$2"
  python3 - "$csv_json_file" "$ops_file" <<'PY'
import json, sys

def unescape(token: str) -> str:
    return token.replace("~1", "/").replace("~0", "~")

def parent_and_key(doc, path: str):
    if path in ("", "/"):
        raise ValueError("cannot address document root for this op")
    parts = [unescape(p) for p in path.lstrip("/").split("/")]
    cur = doc
    for part in parts[:-1]:
        if isinstance(cur, list):
            cur = cur[int(part)]
        else:
            cur = cur[part]
    return cur, parts[-1]

def apply_ops(doc, ops):
    for op in ops:
        kind = op["op"]
        path = op["path"]
        if kind == "remove":
            try:
                parent, key = parent_and_key(doc, path)
            except (KeyError, IndexError, TypeError, ValueError):
                continue
            try:
                if isinstance(parent, list):
                    idx = int(key)
                    if 0 <= idx < len(parent):
                        parent.pop(idx)
                elif isinstance(parent, dict) and key in parent:
                    del parent[key]
            except (KeyError, IndexError, TypeError, ValueError):
                pass
        elif kind in ("add", "replace"):
            parent, key = parent_and_key(doc, path)
            value = op["value"]
            if isinstance(parent, list):
                if kind == "add" and key == "-":
                    parent.append(value)
                elif kind == "add":
                    parent.insert(int(key), value)
                else:
                    parent[int(key)] = value
            else:
                parent[key] = value
        else:
            raise SystemExit(f"unsupported JSON6902 op: {kind}")
    return doc

csv_path, ops_path = sys.argv[1], sys.argv[2]
with open(csv_path) as fh:
    doc = json.load(fh)
with open(ops_path) as fh:
    ops = json.load(fh)
doc = apply_ops(doc, ops)
with open(csv_path, "w") as fh:
    json.dump(doc, fh)
PY
}

mapfile -t PATCH_FILES < <(collect_patch_files)

if [[ ${#PATCH_FILES[@]} -eq 0 ]]; then
  echo "[$(date -u +%FT%T.%3NZ)] No CSV patches in test bundle (no-op)"
  exit 0
fi

echo "[$(date -u +%FT%T.%3NZ)] Applying ${#PATCH_FILES[@]} CSV patch(es) to ${CSV_NAME}"

TMP_CSV=$(mktemp)
TMP_OUT=$(mktemp)
TMP_OPS=$(mktemp)
trap 'rm -f "${TMP_CSV}" "${TMP_OUT}" "${TMP_OPS}"' EXIT
oc get csv "${CSV_NAME}" -n "${INSTALL_NAMESPACE}" -o json > "${TMP_CSV}"

for PATCH in "${PATCH_FILES[@]}"; do
  if [[ ! -f "${PATCH}" ]]; then
    echo "ERROR: CSV patch not found: ${PATCH}" >&2
    exit 1
  fi
  echo "  Applying: ${PATCH#"${BUNDLE_DIR}"/}"

  if json6902_ops "${PATCH}" > "${TMP_OPS}" 2>/dev/null; then
    apply_json6902_to_file "${TMP_CSV}" "${TMP_OPS}"
  else
    oc patch --local -f "${TMP_CSV}" --type=strategic --patch-file="${PATCH}" -o json > "${TMP_OUT}"
    mv "${TMP_OUT}" "${TMP_CSV}"
    TMP_OUT=$(mktemp)
  fi
done

echo "[$(date -u +%FT%T.%3NZ)] Replacing CSV ${CSV_NAME} with patched object"
oc replace -f "${TMP_CSV}"
echo "[$(date -u +%FT%T.%3NZ)] CSV patches applied"
