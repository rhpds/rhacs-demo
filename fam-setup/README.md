# FAM (File Activity Monitoring) Setup

This setup enables file activity monitoring on the SecuredCluster, submits FAM policies to RHACS via the API, and documents how to trigger violations for demonstration.

## Prerequisites

- OpenShift cluster with RHACS (ACS) installed
- `oc` logged in
- `ROX_API_TOKEN` set (from basic-setup or RHACS UI → Platform Configuration → Integrations → API Token)
- `jq` installed

## Quick Start

```bash
# Set credentials (if not in ~/.bashrc)
export ROX_API_TOKEN='your-api-token'
# ROX_CENTRAL_URL is auto-detected from cluster route

# Run the install script
./install.sh
```

## What It Does

1. **Enables file activity monitoring** – Patches the SecuredCluster so `fileActivityMonitoring.mode` is `Enabled`.
2. **Submits FAM policies** – Creates or updates:
   - `fam-basic-node-monitoring` – monitors `/etc/passwd` for node-level modifications (NODE_EVENT)
   - `fam-basic-deploy-monitoring` – monitors deployments for changes to `/etc/passwd`
3. **Applies a demo CronJob** – `fam-cron-alert.yaml` creates `rhacs-fam-trigger`, which periodically runs commands that touch/read `/etc/passwd` inside a pod (schedule and namespace are in the manifest; default namespace is `default`).

## Trigger violations (run after install)

```bash
# 1. Start a debug session on a worker node
oc debug node/<worker-node-name>

# 2. Inside the debug pod, run:
chroot /host
touch /etc/passwd    # Triggers fam-basic-node-monitoring
```

## Note on Policy-as-Code

These policies use `eventSource: NODE_EVENT` (node-level) or `DEPLOYMENT_EVENT` (deployment-level). The SecurityPolicy CR only supports `NOT_APPLICABLE`, `DEPLOYMENT_EVENT`, and `AUDIT_LOG_EVENT`. Policies that rely on node-level file activity must be submitted via the RHACS API (as this script does).

## Files

| File | Description |
|------|-------------|
| `fam-basic-node-monitoring.json` | FAM policy for node events (submitted via API) |
| `fam-basic-deploy-monitoring.json` | FAM policy for deployment events (submitted via API) |
| `fam-cron-alert.yaml` | CronJob `rhacs-fam-trigger` – periodic in-cluster trigger (applied by `install.sh`) |
| `install.sh` | Main script – enables file activity monitoring, submits policies, applies CronJob, prints manual trigger steps |

## View violations

In RHACS UI: **Violations** → filter by policy **fam-basic-node-monitoring**

### Renaming from older demos

If you previously installed policies named `fim-basic-*`, those remain in Central until removed. This repo now ships **`fam-basic-*`** policy names and files; run `install.sh` to create or update the new policies.
