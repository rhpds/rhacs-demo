#!/bin/bash
# Deploy Project Hummingbird demo workloads from demo-applications (parallel with scripts 05–08).
#
# RHACS base image registration runs afterward via 09-deploy-hummingbird-demo.sh.
#
# Requires: oc logged in; demo-applications repo (clone via 04-deploy-applications.sh first)
# Optional: SKIP_HUMMINGBIRD_DEMO=1, DEMO_APPS_DIR

set -euo pipefail

_RHACS_DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${_RHACS_DEMO_ROOT}/setup-rerun-hint.sh"
setup_rerun_register "${BASH_SOURCE[0]}" "$@"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# shellcheck disable=SC1090
source "${_RHACS_DEMO_ROOT}/basic-setup/lib/hummingbird-demo.sh"

main() {
    if [ "${SKIP_HUMMINGBIRD_DEMO:-0}" = "1" ]; then
        print_info "Skipping Hummingbird deploy (SKIP_HUMMINGBIRD_DEMO=1)"
        exit 0
    fi

    print_info "=========================================="
    print_info "Hummingbird Application Deployment"
    print_info "=========================================="
    print_info ""

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift"
        exit 1
    fi

    DEMO_APPS_DIR="$(resolve_demo_apps_dir "${_RHACS_DEMO_ROOT}")"
    export DEMO_APPS_DIR

    if is_hummingbird_deployed; then
        print_info "✓ Hummingbird namespace ${HUMMINGBIRD_NAMESPACE} already exists"
        print_info "Skipping deployment (idempotent)"
        wait_for_hummingbird_deployments
    else
        deploy_hummingbird_applications "${DEMO_APPS_DIR}"
    fi

    print_info ""
    print_info "=========================================="
    print_info "Hummingbird Application Deployment Complete"
    print_info "=========================================="
    print_info ""
}

main "$@"
