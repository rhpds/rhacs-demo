#!/bin/bash
# Shared helpers for Project Hummingbird demo (deploy via demo-applications, RHACS registration).
# Sourced by 09-deploy-hummingbird-demo.sh.

HUMMINGBIRD_NAMESPACE="${HUMMINGBIRD_NAMESPACE:-hummingbird-demo}"
HI_BASE_IMAGE="${HI_BASE_IMAGE:-registry.access.redhat.com/hi/python:3.13}"
HI_LAYERED_IMAGE="${HI_LAYERED_IMAGE:-quay.io/mfoster/hi-python-demo:0.1.0}"

hummingbird_manifests_dir() {
    local demo_apps_dir="${1:-${DEMO_APPS_DIR:-${HOME}/demo-applications}}"
    echo "${demo_apps_dir}/k8s-deployment-manifests/hummingbird-demo"
}

wait_for_hummingbird_deployments() {
    print_step "Waiting for Hummingbird demo deployments..."
    oc rollout status deployment/hi-python-base -n "${HUMMINGBIRD_NAMESPACE}" --timeout=180s 2>/dev/null || \
        print_warn "hi-python-base rollout still in progress"
    oc rollout status deployment/hi-python-layered -n "${HUMMINGBIRD_NAMESPACE}" --timeout=300s 2>/dev/null || \
        print_warn "hi-python-layered rollout still in progress"
}

register_hummingbird_base_image() {
    local token="${1:-${ROX_API_TOKEN:-}}"
    local api_v2="${2:-}"

    if [ -z "${token}" ] || [ -z "${api_v2}" ]; then
        return 0
    fi

    print_step "Registering RHACS base image references..."
    # shellcheck disable=SC1090
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rhacs-base-images.sh"
    register_rhacs_base_images "${token}" "${api_v2}"
}

print_hummingbird_ui_guidance() {
    local route_url
    route_url=$(oc get route hi-python-layered -n "${HUMMINGBIRD_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")

    print_info ""
    print_info "Hummingbird demo workloads (view in RHACS UI after sensor scan):"
    print_info "  Namespace: ${HUMMINGBIRD_NAMESPACE}"
    print_info "  Base deployment: hi-python-base → ${HI_BASE_IMAGE}"
    print_info "  Layered deployment: hi-python-layered → ${HI_LAYERED_IMAGE}"
    if [ -n "${route_url}" ]; then
        print_info "  Layered app route: ${route_url}"
    fi
    print_info ""
    print_info "In RHACS Central:"
    print_info "  Platform Configuration → Image base references"
    print_info "    • ${HI_BASE_IMAGE}"
    print_info "    • docker.io/library/python:3.12-alpine"
    print_info "  Vulnerability Management → Workloads → namespace ${HUMMINGBIRD_NAMESPACE}"
    print_info "  Compare hi-python-base vs hi-python-layered for base vs application layer CVEs"
    print_info "  (enable ROX_POLICY_FILTERS_UI via script 08 for layer filtering in the UI)"
}
