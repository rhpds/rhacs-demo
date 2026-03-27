#!/bin/bash
#
# RHACS Monitoring Setup - Monitoring Stack Installation
# Installs Cluster Observability Operator, monitoring stack, and Perses dashboards
#
# After MonitoringStack + ScrapeConfig apply, verifies:
#   - both CRs exist (ScrapeConfig re-applied once if missing)
#   - Prometheus becomes ready via: discover StatefulSet/Deployment (name patterns vary by COO version),
#     or fall back to pods with label app.kubernetes.io/name=prometheus
#   - on failure, re-applies stack + scrape YAML once then waits again (mitigates first-run races)
#
# Optional env:
#   RHACS_NS / MONITORING_STACK_NAME / SCRAPE_CONFIG_NAME — override defaults if you renamed CRs
#   PROMETHEUS_ROLLOUT_TARGET — explicit "statefulset/name" or "deployment/name" to wait on (skips discovery)
#   COO_PROMETHEUS_WAIT_SEC — max seconds to wait for Prometheus workload/pods (default 300)
#   MONITORING_SKIP_PROMETHEUS_READY_WAIT=1 — only verify MonitoringStack + ScrapeConfig CRs (no STS/pod wait)
#

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RHACS_NS="${RHACS_NS:-stackrox}"
MONITORING_STACK_NAME="${MONITORING_STACK_NAME:-sample-stackrox-monitoring-stack}"
SCRAPE_CONFIG_NAME="${SCRAPE_CONFIG_NAME:-sample-stackrox-scrape-config}"
# Default COO name; many clusters use a different STS name — see discover_prometheus_rollout_target()
DEFAULT_PROMETHEUS_STS_NAME="${MONITORING_STACK_NAME}-prometheus"
MONITORING_STACK_YAML="monitoring-examples/cluster-observability-operator/monitoring-stack.yaml"
SCRAPE_CONFIG_YAML="monitoring-examples/cluster-observability-operator/scrape-config.yaml"

# Discover workload for `oc rollout status`: explicit PROMETHEUS_ROLLOUT_TARGET, or
# default STS name, or any STS/Deploy whose name matches this MonitoringStack / prometheus.
# Prints one line: statefulset/foo or deployment/bar
discover_prometheus_rollout_target() {
  local ns="$1"
  local ms_name="$2"
  local line

  if [ -n "${PROMETHEUS_ROLLOUT_TARGET:-}" ]; then
    echo "${PROMETHEUS_ROLLOUT_TARGET}"
    return 0
  fi

  if oc get "statefulset/${DEFAULT_PROMETHEUS_STS_NAME}" -n "${ns}" &>/dev/null; then
    echo "statefulset/${DEFAULT_PROMETHEUS_STS_NAME}"
    return 0
  fi

  # Prefer STS tied to this MonitoringStack (name contains CR name + prometheus)
  line=$(oc get sts -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -F "${ms_name}" | grep -i prometheus | head -1)
  if [ -n "${line}" ]; then
    echo "statefulset/${line}"
    return 0
  fi

  # Any Prometheus StatefulSet in namespace (COO naming varies by version)
  line=$(oc get sts -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i prometheus | head -1)
  if [ -n "${line}" ]; then
    echo "statefulset/${line}"
    return 0
  fi

  line=$(oc get deploy -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -iE "prometheus.*${ms_name}|${ms_name}.*prometheus|sample-stackrox.*prometheus" | head -1)
  if [ -n "${line}" ]; then
    echo "deployment/${line}"
    return 0
  fi

  return 1
}

# Wait for Ready pods carrying the standard Prometheus label (works when rollout target name differs).
wait_prometheus_pods_ready() {
  local ns="$1"
  local timeout_sec="${2:-120}"
  if ! oc get pods -n "${ns}" -l app.kubernetes.io/name=prometheus -o name 2>/dev/null | grep -q .; then
    return 1
  fi
  oc wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus -n "${ns}" --timeout="${timeout_sec}s" 2>/dev/null
}

# True if Prometheus is already serving: Service has endpoints, or any *prometheus* pod is Ready (COO label/name varies).
prometheus_stack_observable() {
  local ns="$1"
  local svc="${MONITORING_STACK_NAME}-prometheus"
  local addr pod r

  if oc get "svc/${svc}" -n "${ns}" &>/dev/null; then
    addr=$(oc get endpoints "${svc}" -n "${ns}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
    if [ -n "${addr}" ]; then
      return 0
    fi
    addr=$(oc get endpointslice -n "${ns}" -l "kubernetes.io/service-name=${svc}" -o jsonpath='{.items[0].endpoints[0].addresses[0]}' 2>/dev/null || true)
    if [ -n "${addr}" ]; then
      return 0
    fi
  fi

  while IFS= read -r pod; do
    [ -z "${pod}" ] && continue
    r=$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    if [ "${r}" = "True" ]; then
      return 0
    fi
  done < <(oc get pods -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i prometheus || true)

  return 1
}

# Wait for operator Prometheus workload: discovered STS/Deploy rollout, else pod readiness.
wait_for_coo_prometheus_ready() {
  local attempt_label="$1"
  local max_wait="${COO_PROMETHEUS_WAIT_SEC:-300}"
  local elapsed=0
  local step_wait=10
  local target

  if prometheus_stack_observable "${RHACS_NS}"; then
    log "✓ Prometheus already operational (Service endpoints or Ready *prometheus* pod) — ${attempt_label}"
    return 0
  fi

  while [ "${elapsed}" -lt "${max_wait}" ]; do
    if prometheus_stack_observable "${RHACS_NS}"; then
      log "✓ Prometheus became operational — ${attempt_label}"
      return 0
    fi
    if target=$(discover_prometheus_rollout_target "${RHACS_NS}" "${MONITORING_STACK_NAME}"); then
      log "✓ Prometheus workload found: ${target} (${attempt_label})"
      if oc rollout status "${target}" -n "${RHACS_NS}" --timeout=240s; then
        log "✓ Rollout complete (${target})"
        return 0
      fi
      warn "rollout not finished for ${target} — checking pod readiness..."
      if wait_prometheus_pods_ready "${RHACS_NS}" 120; then
        log "✓ Prometheus pod(s) Ready (workload: ${target})"
        return 0
      fi
    fi

    if wait_prometheus_pods_ready "${RHACS_NS}" 45; then
      log "✓ Prometheus pod(s) Ready via label app.kubernetes.io/name=prometheus (${attempt_label})"
      return 0
    fi

    log "  Waiting for Prometheus workload or pods... (${elapsed}s/${max_wait}s)"
    sleep "${step_wait}"
    elapsed=$((elapsed + step_wait))
  done
  return 1
}

verify_scrape_config_present() {
  if oc get scrapeconfig "${SCRAPE_CONFIG_NAME}" -n "${RHACS_NS}" &>/dev/null; then
    log "✓ ScrapeConfig ${SCRAPE_CONFIG_NAME} present in ${RHACS_NS}"
    return 0
  fi
  return 1
}

verify_monitoring_stack_cr() {
  if oc get monitoringstack "${MONITORING_STACK_NAME}" -n "${RHACS_NS}" &>/dev/null; then
    log "✓ MonitoringStack CR ${MONITORING_STACK_NAME} present in ${RHACS_NS}"
    return 0
  fi
  return 1
}

# After applies: confirm CRs exist, Prometheus is ready; optionally re-apply once on failure.
verify_and_finalize_coo_stack() {
  echo ""
  step "Verifying Cluster Observability stack (MonitoringStack / ScrapeConfig / Prometheus)"
  echo ""

  if ! verify_monitoring_stack_cr; then
    error "MonitoringStack CR missing — apply may have failed silently"
    return 1
  fi

  if ! verify_scrape_config_present; then
    warn "ScrapeConfig not found — re-applying ${SCRAPE_CONFIG_YAML}..."
    oc apply -f "${SCRAPE_CONFIG_YAML}"
    sleep 5
    if ! verify_scrape_config_present; then
      error "ScrapeConfig ${SCRAPE_CONFIG_NAME} still missing after re-apply"
      return 1
    fi
  fi

  if [ "${MONITORING_SKIP_PROMETHEUS_READY_WAIT:-0}" = "1" ]; then
    warn "Skipping Prometheus readiness wait (MONITORING_SKIP_PROMETHEUS_READY_WAIT=1) — CRs only"
    return 0
  fi

  if wait_for_coo_prometheus_ready "attempt 1"; then
    return 0
  fi

  warn "Prometheus StatefulSet not ready on first wait — re-applying stack + scrape, then retrying..."
  oc apply -f "${MONITORING_STACK_YAML}"
  oc apply -f "${SCRAPE_CONFIG_YAML}"
  sleep 15

  if wait_for_coo_prometheus_ready "attempt 2 (after re-apply)"; then
    return 0
  fi

  error "Prometheus did not become ready — check: oc get sts,deploy,pod -n ${RHACS_NS} | grep -i prometheus; oc describe monitoringstack ${MONITORING_STACK_NAME} -n ${RHACS_NS}; optional: export PROMETHEUS_ROLLOUT_TARGET=statefulset/<name>"
  return 1
}

step "Monitoring Stack Installation"
echo "=========================================="
echo ""

# Ensure we're in the stackrox namespace
log "Switching to stackrox namespace..."
oc project stackrox

# Per RHACS 4.10 docs 15.2.1: Disable OpenShift monitoring when using custom Prometheus
# https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.10/html/configuring/monitor-acs
CENTRAL_CR=$(oc get central -n stackrox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$CENTRAL_CR" ]; then
  log "Disabling OpenShift monitoring on Central (required for custom Prometheus)..."
  if oc patch central "$CENTRAL_CR" -n stackrox --type=merge -p='{"spec":{"monitoring":{"openshift":{"enabled":false}}}}' 2>/dev/null; then
    log "✓ OpenShift monitoring disabled"
  elif oc patch central "$CENTRAL_CR" -n stackrox --type=merge -p='{"spec":{"central":{"monitoring":{"openshift":{"enabled":false}}}}}' 2>/dev/null; then
    log "✓ OpenShift monitoring disabled"
  else
    warn "Could not patch Central CR - ensure monitoring.openshift.enabled: false is set manually"
  fi
else
  warn "Central CR not found - skip disabling OpenShift monitoring (Helm/other install)"
fi

echo ""
log "Installing Cluster Observability Operator..."
oc apply -f monitoring-examples/cluster-observability-operator/subscription.yaml
log "✓ Cluster Observability Operator subscription created"

echo ""
log "Installing and configuring monitoring stack instance..."
max_wait=300
elapsed=0
while [ $elapsed -lt $max_wait ]; do
  if out=$(oc apply -f "$MONITORING_STACK_YAML" 2>&1); then
    echo "$out"
    log "✓ MonitoringStack applied"
    break
  fi
  if echo "$out" | grep -qE "no matches for kind \"MonitoringStack\"|ensure CRDs are installed first"; then
    log "  Waiting for operator CRDs... (${elapsed}s/${max_wait}s)"
    sleep 15
    elapsed=$((elapsed + 15))
  else
    echo "$out" >&2
    exit 1
  fi
done
if [ $elapsed -ge $max_wait ]; then
  error "MonitoringStack apply failed after ${max_wait}s - operator may not be ready"
  exit 1
fi

if out=$(oc apply -f "$SCRAPE_CONFIG_YAML" 2>&1); then
  echo "$out"
  log "✓ ScrapeConfig applied"
else
  echo "$out" >&2
  error "ScrapeConfig apply failed"
  exit 1
fi

if ! verify_and_finalize_coo_stack; then
  exit 1
fi

echo ""
log "Installing Prometheus Operator resources (for clusters with Prometheus Operator)..."
if oc get crd prometheuses.monitoring.coreos.com &>/dev/null; then
  oc apply -f monitoring-examples/prometheus-operator/
  log "✓ Prometheus Operator resources applied"
else
  log "Prometheus Operator CRD not found - skipping"
fi

echo ""
log "Installing Perses and configuring the RHACS dashboard..."
oc apply -f monitoring-examples/perses/ui-plugin.yaml
log "✓ Perses UI Plugin created"

oc apply -f monitoring-examples/perses/datasource.yaml
log "✓ Perses Datasource created"

# Perses operator conversion webhook may not be ready on first run - retry if creation fails
log "Creating Perses Dashboard..."
DASHBOARD_YAML="monitoring-examples/perses/dashboard.yaml"
max_retries=4
retry_delay=30
for attempt in $(seq 1 $max_retries); do
  if out=$(oc apply -f "$DASHBOARD_YAML" 2>&1); then
    echo "$out"
    log "✓ Perses Dashboard created"
    break
  fi
  echo "$out" >&2
  if [ $attempt -lt $max_retries ] && echo "$out" | grep -qE "perses-operator-conversion-webhook|conversion webhook.*failed"; then
    warn "Perses operator webhook not ready yet - waiting ${retry_delay}s before retry (attempt $attempt/$max_retries)..."
    sleep $retry_delay
  else
    error "Perses Dashboard creation failed"
    exit 1
  fi
done

echo ""
log "✓ Monitoring stack installation complete"
echo ""