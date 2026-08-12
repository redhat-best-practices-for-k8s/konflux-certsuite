# Konflux Certsuite Test

A [Konflux](https://konflux-ci.dev/) integration test pipeline that deploys an
operator from an FBC (File-Based Catalog) fragment, runs the
[Red Hat Best Practices Test Suite for Kubernetes](https://github.com/redhat-best-practices-for-k8s/certsuite)
(certsuite) against it, and collects results.

## Two Pipeline Variants

### EaaS (Recommended)

`certsuite-operator-test-eaas.yaml` -- provisions a fresh ephemeral
Hypershift cluster per run via Konflux EaaS. No kubeconfig secrets, no
cluster locks, no OADP. The cluster is automatically destroyed when the
run completes.

### Shared Cluster

`certsuite-operator-test.yaml` -- uses a pre-existing cluster via a
kubeconfig Secret. Includes Lease-based queueing and OADP
backup/restore. Use this only when your tests require persistent
infrastructure (e.g. hardware-dependent tests).

## Key Features

- **Operator test bundle** -- operator owners provide a portable bundle of
  software-only operand manifests so the full operator scope is exercised
  without hardware or license dependencies.
- **All tests by default** -- runs the full certsuite suite unless
  `CERTSUITE_LABELS` specifies a subset.
- **OCI results storage (EaaS)** -- claim/results are pushed as an OCI
  artifact via `oras`, either to the component Quay repo
  (`OCI_PUSH_SECRET`) or to a dedicated external registry
  (`OCI_RESULTS_REPO` + `OCI_RESULTS_SECRET`).
- **Results to cert-track-results** -- claim.json is optionally pushed to
  the cert-track-results web app with retention policies (shared-cluster
  variant).

## Quick Start

See the [Architecture Guide](docs/architecture.md) for the full workflow and
the [Operator Onboarding Guide](docs/operator-onboarding-guide.md) for
step-by-step instructions on creating a test bundle and adding the test to your
Konflux application.

## Repository Layout

```
pipelines/          Tekton Pipeline definitions
tasks/              Reusable Tekton Task definitions
scripts/            Shell scripts used by the tasks
tools/              Scaffolding & validation helpers for operator owners
docs/               Architecture and onboarding documentation
examples/           Example IntegrationTestScenario, OADP backup, test bundle
```

## EaaS Pipeline Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `SNAPSHOT` | auto | -- | Provided by Konflux |
| `TEST_BUNDLE_REF` | yes | -- | Git URL to the operator test bundle (`URL[@rev][#path]`) |
| `CERTSUITE_LABELS` | no | `common` | Comma-separated certsuite labels |
| `PACKAGE_NAME` | no | auto-detect | OLM package name |
| `CHANNEL_NAME` | no | auto-detect | OLM channel name |
| `IMAGES_MIRROR_SET_REF` | no | from `TEST_BUNDLE_REF` | Optional override for `.tekton/images-mirror-set.yaml` |
| `OCI_PUSH_SECRET` | no | placeholder | `dockerconfigjson` Secret for pushing results to the component Quay repo |
| `OCI_RESULTS_REPO` | no | `""` | Bare external OCI repo (no tag/digest). When set, results go here instead of the component repo |
| `OCI_RESULTS_SECRET` | no* | placeholder | `dockerconfigjson` Secret with push access to `OCI_RESULTS_REPO` (*required when that repo is set) |
| `RELEASE` | no | `""` | Optional release/stream label for external OCI tags (e.g. `5.0` → `…-5.0-pr-…` / `…-5.0-merged-…`) |
| `REGISTRY_PULL_SECRET` | no | placeholder | `dockerconfigjson` Secret for `get-unreleased-bundle` pulls (e.g. `registry.redhat.io`); falls back to SA-linked secrets |

See [OCI Results Storage](pipelines/certsuite-operator-test/0.1/README.md#oci-results-storage) for setup and download instructions.

## Shared Cluster Pipeline Parameters

Uses a different collect-results path (`OCI_REF`, cert-track params) plus cluster management:

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `KUBECONFIG_SECRET_NAME` | no | `shared-cluster-kubeconfig` | Secret holding the kubeconfig |
| `KUBECONFIG_VALUE` | no | `""` | Base64 kubeconfig for testing; auto-creates a temporary Secret |
| `OCI_REF` | no | `""` | Explicit OCI artifact ref for results; empty skips |
| `CERT_TRACK_URL` | no | `""` | cert-track-results URL; empty skips |
| `CERT_TRACK_SECRET_NAME` | no | `""` | cert-track API token secret |
| `OADP_BACKUP_NAME` | no | `certsuite-clean-baseline` | OADP Backup name; first run creates it; empty skips OADP |
| `LOCK_TIMEOUT` | no | `1800` | Seconds to wait for cluster lock |
| `LOCK_NAME` | no | `certsuite-cluster-lock` | Lease name for the mutex |

## License

Apache License 2.0
