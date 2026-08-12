# Operator Onboarding Guide

This guide walks operator owners through creating a **certsuite test
bundle**, testing it locally, and onboarding their operator to the
Konflux certsuite shared test pipeline.

## What Is a Test Bundle?

A test bundle is a directory in your operator's git repository that
contains everything needed to deploy a **software-only** version of
your operator's workloads for testing. "Software-only" means:

- No specialized hardware (SR-IOV NICs, GPUs, FPGAs, PTP clocks)
- No license keys or entitlements
- No external service dependencies (cloud APIs, databases)
- No PersistentVolumes requiring specific storage classes

The goal is a portable, self-contained set of manifests that deploys
your operator's operands on any OpenShift cluster so the pipeline can
verify the operator is properly deployed and then run certsuite against
it.

The test bundle is **not** responsible for certsuite configuration --
that is managed separately via the `CERTSUITE_CONFIG_SECRET` pipeline
parameter. By default, the pipeline runs **all** certsuite tests
unless a subset is specified via `CERTSUITE_LABELS`.

## Bundle Directory Structure

```
my-operator-test-bundle/
  certsuite-test-bundle.yaml       # Required: bundle metadata
  operands/                        # Required: operand manifests
    my-custom-resource.yaml        #   Your operator's CR instances
    deployment.yaml                #   Any additional workloads
    service.yaml                   #   Services, etc.
  prerequisites/                   # Optional: pre-deploy resources
    pull-secret.yaml               #   Secrets, ConfigMaps, etc.
  csv-patches/                     # Optional: CSV patches (JSON6902 / strategic-merge)
    00-remove-min-kube-version.json
```

## Step 1: Create the Bundle Manifest

Create `certsuite-test-bundle.yaml` at the root of your bundle directory:

```yaml
apiVersion: certsuite.redhat.com/v1alpha1
kind: TestBundle
metadata:
  name: my-operator-test-bundle
  labels:
    app.kubernetes.io/part-of: my-operator
spec:
  # Namespace for operator install AND operand deployment.
  # Leave empty to fall back to CSV suggested-namespace, then auto-generate.
  namespace: ""

  # OLM install mode. One of: AllNamespaces, OwnNamespace,
  # SingleNamespace, MultiNamespace.
  # Leave empty to auto-detect from CSV supported modes
  # (prefers AllNamespaces, then OwnNamespace).
  installMode: ""

  description: |
    Software-only test deployment of my-operator.

  # Certsuite discovery labels applied after operator install.
  # Omit to use defaults: CSV gets "operator=target", all DaemonSets get
  # "generic=target" on their pod templates.
  discoveryLabels:
    operator: "redhat-best-practices-for-k8s.com/operator=target"
    pod: "redhat-best-practices-for-k8s.com/generic=target"
    resources:
      - kind: Deployment       # Which resource kinds to label

  # Optional: CSV patches applied after OLM creates the CSV and before
  # waiting for Succeeded. Prefer listing paths here; if omitted, the
  # pipeline auto-loads csv-patches/* when that directory exists.
  # csvPatches:
  #   - path: csv-patches/00-remove-min-kube-version.json

  # The pipeline verifies these resources before running certsuite.
  # Deployment, StatefulSet, DaemonSet: rollout readiness (waits for pods).
  # Any other kind: presence check (verifies the resource exists).
  readiness:
    timeout: 300                   # Seconds to wait
    checks:
      - kind: Deployment
        name: my-controller
      - kind: DaemonSet
        name: my-agent
      - kind: MyCustomResource     # Presence check only
        name: test-instance
```

The operator's package name and channel are **not** specified here --
Konflux determines those from the FBC fragment in the Snapshot.

### Install Configuration

| Field | Values | Default | Description |
|-------|--------|---------|-------------|
| `namespace` | Any string | CSV `suggested-namespace`, then auto-generate `oo-*` | Namespace for both operator install and operand deployment |
| `installMode` | `AllNamespaces`, `OwnNamespace`, `SingleNamespace`, `MultiNamespace` | Auto-detect from CSV (prefers AllNamespaces, then OwnNamespace) | Determines the OperatorGroup target namespaces |

### Discovery Labels

The pipeline applies discovery labels so certsuite can find the operator
CSV and its workload pods. You can customize which labels and which
resource types get labeled:

| Field | Default | Description |
|-------|---------|-------------|
| `discoveryLabels.operator` | `redhat-best-practices-for-k8s.com/operator=target` | Label applied to the installed CSV |
| `discoveryLabels.pod` | `redhat-best-practices-for-k8s.com/generic=target` | Label applied to workload pod templates |
| `discoveryLabels.resources[].kind` | `DaemonSet` | Resource types to label (`Deployment`, `DaemonSet`, `StatefulSet`) |

If your operator's workloads are Deployments (not DaemonSets), set
`resources` to `[{kind: Deployment}]`. For operators with both, list
both kinds.

### Optional CSV patches

Any install-time CSV tweaks (for example HyperShift constraints such as
removing `minKubeVersion` or a master `nodeSelector`) belong in the test
bundle — not in the shared pipeline.

Supported patch forms:

| Form | Detection | Application |
|------|-----------|-------------|
| JSON6902 | `.json` array, or YAML list of `{op,path,...}` | Applied locally, then `oc replace` |
| Strategic merge | YAML/JSON object | `oc patch --local --type=strategic` |

See [examples/ptp-operator-test-bundle/csv-patches/](../examples/ptp-operator-test-bundle/csv-patches/)
for the PTP HyperShift reference patches.

### Supported Check Types

| Kind | Behavior |
|------|----------|
| `Deployment` | Waits for rollout to complete (all pods Ready) |
| `StatefulSet` | Waits for rollout to complete |
| `DaemonSet` | Waits for rollout to complete |
| Any other kind | Verifies the resource exists (namespace-scoped first, then cluster-scoped) |

If no `readiness.checks` are defined, the pipeline auto-discovers all
Deployments in the target namespace and waits for them.

## Step 2: Create Operand Manifests

Place Kubernetes manifests in the `operands/` directory. These are
applied with `oc apply -f operands/` after the operator is installed.

### Custom Resources

If your operator reconciles Custom Resources, create minimal CR
instances that your operator will reconcile. Use test/development
profiles if your operator supports them:

```yaml
# operands/my-app.yaml
apiVersion: myoperator.example.com/v1
kind: MyApp
metadata:
  name: test-instance
spec:
  replicas: 1
  profile: test         # Use a lightweight profile
  storage:
    type: emptyDir      # Avoid PVC requirements
  features:
    hardware-offload: false
    external-auth: false
```

### Direct Workloads

If your operator does not auto-create workloads from CRs, include
explicit Deployment manifests:

```yaml
# operands/workload.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-workload
  labels:
    app: my-workload
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-workload
  template:
    metadata:
      labels:
        app: my-workload
    spec:
      containers:
        - name: app
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command: ["sleep", "infinity"]
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
```

### What to Avoid

| Avoid | Why | Alternative |
|-------|-----|-------------|
| PVCs with specific StorageClasses | May not exist on test cluster | Use `emptyDir` volumes |
| NodeSelectors for specialized hardware | Nodes won't have the hardware | Remove or use `preferredDuringScheduling` |
| External service endpoints | Not available in test env | Use mock services or in-cluster alternatives |
| License/entitlement Secrets | Not shareable | Disable features that require them |

Some operators legitimately require `hostNetwork`, privileged containers,
or other elevated permissions. Certsuite will flag these, but they can be
addressed with exceptions in cert-track-results. Do not change your
operator's actual requirements just to pass validation.

## Step 3: Add Prerequisites (Optional)

If your operands need Secrets, ConfigMaps, or RBAC resources before
they can start, place them in a `prerequisites/` directory:

```yaml
# prerequisites/test-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-operator-test-config
data:
  mode: "test"
  log_level: "debug"
```

These are applied before the operand manifests.

## Step 4: Validate Locally

Use the provided validation tool to check your bundle before pushing:

```bash
# From the konflux-certsuite repository
./tools/validate-test-bundle.sh /path/to/your/test-bundle
```

The tool checks:
- `certsuite-test-bundle.yaml` exists and has required fields
- `operands/` directory exists and contains at least one manifest
- YAML syntax is valid

### Test Against a Local Cluster

For a more thorough local test:

```bash
# 1. Install your operator on a test cluster
# 2. Apply the bundle manifests
oc apply -f my-test-bundle/prerequisites/ 2>/dev/null || true
oc apply -f my-test-bundle/operands/

# 3. Wait for readiness
oc rollout status deployment/my-workload

# 4. Verify the operator reconciled your CRs
oc get <your-cr-kind> -n <namespace>
```

## Step 5: Scaffold with the CLI Tool

To generate a boilerplate test bundle:

```bash
./tools/scaffold-test-bundle.sh \
  --name my-operator \
  --output /path/to/output
```

This creates a complete bundle directory with placeholder manifests
that you can customize.

## Step 6: Onboard to Konflux

### Option A: EaaS (Recommended)

No kubeconfig, locks, or OADP to manage. Each run gets a fresh cluster.
OCI results push is optional and needs a registry Secret only if you enable it.

1. **Push the test bundle** to your operator's git repository.

2. **Create an IntegrationTestScenario** using the EaaS pipeline.
   See [examples/integration-test-scenario-eaas.yaml](../examples/integration-test-scenario-eaas.yaml).

   The only required parameter is `TEST_BUNDLE_REF`:
   ```yaml
   params:
     - name: TEST_BUNDLE_REF
       value: "https://github.com/org/repo.git#certsuite-test-bundle"
   resolverRef:
     resolver: git
     params:
       - name: url
         value: https://github.com/redhat-best-practices-for-k8s/konflux-certsuite.git
       - name: pathInRepo
         value: pipelines/certsuite-operator-test/0.1/certsuite-operator-test-eaas.yaml
   ```

3. **(Optional) Configure OCI results storage.** By default, results can be
   pushed to the component Quay repo with `OCI_PUSH_SECRET`. To use a
   dedicated external registry instead:

   ```bash
   oc create secret docker-registry certsuite-results-push-secret \
     --docker-server=<registry-host> \
     --docker-username=<username> \
     --docker-password=<token-or-password> \
     -n <tenant-namespace>
   ```

   ```yaml
   params:
     - name: TEST_BUNDLE_REF
       value: "https://github.com/org/repo.git#certsuite-test-bundle"
     - name: OCI_RESULTS_REPO
       value: "quay.io/<org>/certsuite-results"   # bare repo, no tag/digest
     - name: OCI_RESULTS_SECRET
       value: "certsuite-results-push-secret"
     - name: RELEASE
       value: "5.0"   # optional; produces …-5.0-pr-… / …-5.0-merged-…
   ```

   See [OCI Results Storage](../pipelines/certsuite-operator-test/0.1/README.md#oci-results-storage)
   for tag formats, validation rules, and download instructions.

4. **Merge a change** to your FBC component. The pipeline triggers
   automatically on push events.

### Option B: Shared Cluster

Use when you need a persistent cluster (e.g. hardware tests).

1. **Push the test bundle** to your operator's git repository.

2. **Create Secrets** in your Konflux tenant namespace:

   ```bash
   # Shared cluster kubeconfig
   oc create secret generic shared-cluster-kubeconfig \
     --from-file=kubeconfig=/path/to/kubeconfig \
     -n <tenant-namespace>
   ```

3. **Create an IntegrationTestScenario** using the shared-cluster pipeline.
   See [examples/integration-test-scenario.yaml](../examples/integration-test-scenario.yaml).

   ```yaml
   resolverRef:
     resolver: git
     params:
       - name: pathInRepo
         value: pipelines/certsuite-operator-test/0.1/certsuite-operator-test.yaml
   ```

4. **Merge a change** to your FBC component.

## Example: ptp-operator

The ptp-operator test bundle at
[examples/ptp-operator-test-bundle/](../examples/ptp-operator-test-bundle/)
demonstrates a real-world bundle:

- **PtpOperatorConfig** patches the default config to schedule
  linuxptp-daemon on worker nodes
- **PtpConfig** uses software-only mode (`time_stamping: software`,
  `free_running: 1`) so no PTP-capable NICs are required
- The operator reconciles these CRs and creates the linuxptp-daemon
  DaemonSet, which is enough to verify proper deployment

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| "certsuite-test-bundle.yaml not found" | Wrong `TEST_BUNDLE_REF` path | Check the `#path` fragment in the ref |
| Operands never become Ready | Missing dependencies or bad config | Test locally first (Step 4) |
| EaaS cluster provision timeout | MCE/Hypershift issue | Check Konflux status; retry |
| Lock timeout (shared cluster only) | Another pipeline is running | Increase `LOCK_TIMEOUT` or wait |
| OADP restore fails (shared cluster only) | Backup expired or missing | Recreate the baseline backup |

## Reference

- [Architecture Guide](architecture.md)
- [Certsuite Documentation](https://redhat-best-practices-for-k8s.github.io/certsuite/)
- [Certsuite Configuration](https://redhat-best-practices-for-k8s.github.io/certsuite/configuration/)
- [Certsuite Test Catalog](https://github.com/redhat-best-practices-for-k8s/certsuite/blob/main/CATALOG.md)
