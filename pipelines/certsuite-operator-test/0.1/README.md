# certsuite-operator-test pipelines

Two pipeline variants for running the Red Hat Best Practices Test Suite
for Kubernetes (certsuite) against an operator deployed from an FBC
fragment.

## EaaS Variant (Recommended)

**File:** `certsuite-operator-test-eaas.yaml`

Provisions a fresh ephemeral Hypershift cluster per run via Konflux
EaaS. No kubeconfig secrets, cluster locks, or OADP needed. The
cluster is automatically destroyed when the PipelineRun completes.

### Flow

1. `parse-metadata` -- extract snapshot info
2. `provision-eaas-space` -- allocate EaaS space
3. `get-unreleased-bundle` -- get catalog bundle ref + resolve quay.io bundle
4. `pick-cluster-params` -- OCP version/arch from the pullable quay bundle
5. `build-image-content-sources` -- load `.tekton/images-mirror-set.yaml`
   (from `TEST_BUNDLE_REF` repo by default) → Hypershift `imageContentSources`
6. `provision-cluster` -- create ephemeral cluster with those mirrors (HCCO
   applies a managed IDMS; `registry.redhat.io` pulls redirect to quay.io)
7. `deploy-and-test` -- fetches the test bundle, reads install config
   (`namespace`, `installMode`, `discoveryLabels`) from it, deploys the
   operator via OLM with the correct OperatorGroup, applies optional CSV
   patches, applies discovery labels to the CSV and workload pods,
   deploys operands, runs certsuite

### Minimum Parameters

- `TEST_BUNDLE_REF` — always required. For unreleased operators, point it at
  the **operator monorepo** that also contains `.tekton/images-mirror-set.yaml`
  (Konflux/Conforma convention). The pipeline discovers that file automatically.
- `IMAGES_MIRROR_SET_REF` — optional override if the mirror set lives elsewhere.

Released operators on `registry.redhat.io` need no mirror set (skipped when the
FBC is not on `quay.io/redhat-user-workloads`).

### All EaaS Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `TEST_BUNDLE_REF` | Yes | — | Git ref to the test bundle (`url@branch#path`) |
| `IMAGES_MIRROR_SET_REF` | No | auto-discovered from `TEST_BUNDLE_REF` repo at `.tekton/images-mirror-set.yaml` | Git ref to the ImageDigestMirrorSet for unreleased image mirroring. Set explicitly only if the file is in a different repo or non-standard path. |
| `OCI_PUSH_SECRET` | No | — | `dockerconfigjson` Secret for pushing results to the component Quay repo |
| `OCI_RESULTS_REPO` | No | — | Bare OCI repo for external results storage (alternative to component repo) |
| `OCI_RESULTS_SECRET` | No | — | Push secret for `OCI_RESULTS_REPO` |
| `CERTSUITE_LABELS` | No | `common` | Comma-separated test labels or logical expression |
| `REGISTRY_PULL_SECRET` | No | SA-linked credentials | `dockerconfigjson` Secret for `registry.redhat.io`. Only needed if the SA doesn't already have credentials linked. |
| `PACKAGE_NAME` | No | auto-detected from FBC | Operator package name override |
| `CHANNEL_NAME` | No | auto-detected from FBC | OLM channel override |
| `PIPELINE_SCRIPTS_REF` | No | same repo/branch as pipeline | Git ref to pipeline scripts (advanced — used for testing pipeline changes from forks) |

### Registry Pull Secret (optional)

`get-unreleased-bundle` needs to pull/inspect images from registries such as
`registry.redhat.io`. By default it uses dockerconfig secrets linked on the
PipelineRun ServiceAccount (`konflux-integration-runner`).

To avoid namespace-wide SA linking, pass a Secret name as an ITS param:

```yaml
params:
  - name: REGISTRY_PULL_SECRET
    value: "telco-5g-redhat-pull-secret"   # kubernetes.io/dockerconfigjson in the tenant
```

When the Secret exists its registry auths are **merged** with SA-linked
credentials (Quay component pull secrets are kept; `registry.redhat.io`
entries are added). When unset, placeholder, or missing, only SA-linked
credentials are used.

### OCI Results Storage

By default results are pushed to the component's Quay repo (via `OCI_PUSH_SECRET`)
with tag `<pr|merged>-<timestamp>`.

To push to an **external** OCI registry instead (Quay, docker.io, or any
OCI-compliant host):

| Parameter | Required | Description |
|-----------|----------|-------------|
| `OCI_RESULTS_REPO` | Yes | Bare OCI repo reference (e.g. `quay.io/my-org/certsuite-results` or `docker.io/my-org/certsuite-results`). Must not include a tag or digest. |
| `OCI_RESULTS_SECRET` | Yes | Name of a `kubernetes.io/dockerconfigjson` Secret in the tenant namespace with push access to `OCI_RESULTS_REPO`. |
| `RELEASE` | No | Optional release/stream label (e.g. `5.0`) in the tag and as OCI annotations. |

Create the secret (example for docker.io / Hub):

```bash
oc create secret docker-registry certsuite-results-push-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=<username> \
  --docker-password=<token-or-password> \
  -n <tenant-namespace>
```

Then set in your `IntegrationTestScenario`:

```yaml
params:
  - name: OCI_RESULTS_REPO
    value: "docker.io/<org>/<repo>"
  - name: OCI_RESULTS_SECRET
    value: "certsuite-results-push-secret"
  - name: RELEASE
    value: "5.0"   # optional
```

Credentials are strictly isolated: the component push secret is never sent to
the external registry, and vice-versa.

**Tag format** (no `certsuite-results-` prefix):
`<package>[-<release>]-<pr|merged>-<timestamp>`
e.g. `openperouter-operator-5.0-pr-20260812-183001`

**OCI annotations** on every push:
| Annotation | Value |
|------------|--------|
| `certsuite.redhat.com/trigger` | `pr` or `merged` (from PipelineRun event-type) |
| `certsuite.redhat.com/release` | `RELEASE` when set |
| `org.opencontainers.image.version` | `RELEASE` when set |
| `quay.expires-after` | `7d` for **PR** artifacts only (Quay GC) |

The `pr`/`merged` segment is derived from
`pac.test.appstudio.openshift.io/event-type` via `parse-metadata`.

**Failure policy** (`push-results` uses `onError: continue` — never fails the PipelineRun):

| Situation | Behavior |
|-----------|----------|
| `OCI_RESULTS_REPO` unset | Component-repo path (unchanged). Missing `OCI_PUSH_SECRET` → WARNING + skip. |
| `OCI_RESULTS_REPO` set, secret missing/empty | ERROR and step fails clearly (no fallback to `OCI_PUSH_SECRET`). |
| `OCI_RESULTS_REPO` has a tag/digest | ERROR: must be a bare repo reference. |
| `oras push` auth/network failure | ERROR naming the target + which secret to fix; step fails, pipeline continues. |

Download from the `push-results` log line after a successful push:

```bash
oras pull <host>/<repo>:<package>[-<release>]-<pr|merged>-<timestamp>
tar xzf certsuite-results.tar.gz
```

## Shared Cluster Variant

**File:** `certsuite-operator-test.yaml`

Uses a pre-existing cluster via a kubeconfig Secret. Includes
Lease-based queueing for concurrent access and OADP backup/restore for
cluster state management.

### Flow

1. `parse-metadata` -- extract snapshot info
2. `get-unreleased-bundle` -- get operator bundle from FBC
3. `acquire-cluster-lock` -- Lease mutex on shared cluster
4. `oadp-restore-pre` -- restore to clean baseline (first run creates backup)
5. `deploy-operator` -- fetches the test bundle, reads install config
   from it, installs operator via OLM with bundle-driven namespace,
   installMode, and discovery labels
6. `deploy-operands` -- apply test bundle manifests, run readiness checks
7. `run-certsuite` -- run test suites
8. `collect-results` -- optionally push results
9. **finally:** cleanup-operator, oadp-restore-post, release-cluster-lock

### Minimum Parameters

`TEST_BUNDLE_REF` + a `shared-cluster-kubeconfig` Secret in the tenant
namespace.

## Usage

Create an `IntegrationTestScenario` in your tenants-config repo. See:
- [EaaS example](../../../examples/integration-test-scenario-eaas.yaml) (recommended)
- [Shared cluster example](../../../examples/integration-test-scenario.yaml)
