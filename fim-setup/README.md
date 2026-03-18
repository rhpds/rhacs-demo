# FIM (File Integrity Monitoring) Setup

This setup deploys a FIM policy to RHACS and triggers violations for demonstration.

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

1. **Enables file activity monitoring** – Patches the SecuredCluster to enable FIM (`fileActivityMonitoring.mode: Enabled`).
2. **Submits FIM policies** – Creates or updates:
   - `fim-basic-node-monitoring` – monitors `/etc/passwd` for node-level modifications (NODE_EVENT)
   - `fim-basic-deploy-monitoring` – monitors deployments for changes to `/etc/passwd`

## Trigger FIM Violations (run after install)

```bash
# 1. Start a debug session on a worker node
oc debug node/<worker-node-name>

# 2. Inside the debug pod, run:
chroot /host
touch /etc/passwd    # Triggers fim-basic-node-monitoring
```

## Note on Policy-as-Code

FIM (File Integrity Monitoring) policies use `eventSource: NODE_EVENT` (node-level) or `DEPLOYMENT_EVENT` (deployment-level). The SecurityPolicy CR only supports `NOT_APPLICABLE`, `DEPLOYMENT_EVENT`, and `AUDIT_LOG_EVENT`. Therefore, FIM policies must be submitted via the RHACS API.

## Files

| File | Description |
|------|-------------|
| `fim-basic-node-monitoring.json` | FIM policy for node events (submitted via API) |
| `fim-basic-deploy-monitoring.json` | FIM policy for deployment events (submitted via API) |
| `install.sh` | Main script – enables FIM, submits policies, prints trigger commands |

## View Violations

In RHACS UI: **Violations** → filter by policy **fim-basic-node-monitoring**
