#!/bin/bash

# Script: 02-deploy-sample-vms.sh
# Description: Apply rhel-webserver-vm.yaml with org ID + activation key substituted (RHSM)
# Requires: 01-configure-rhacs.sh run first (RHACS + VSOCK)

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_TEMPLATE="${SCRIPT_DIR}/vm-templates/rhel-webserver-vm.yaml"

# Check prerequisites
if ! oc whoami &>/dev/null; then
    print_error "Not connected to OpenShift cluster"
    exit 1
fi

if [ ! -f "${VM_TEMPLATE}" ]; then
    print_error "VM template not found: ${VM_TEMPLATE}"
    exit 1
fi

# Red Hat Subscription Manager: organization ID + activation key (see https://access.redhat.com/management/activation_keys)
if [ -z "${SUBSCRIPTION_ORG_ID:-}" ]; then
    echo ""
    print_step "Red Hat subscription (organization ID + activation key)"
    read -r -p "Organization ID: " SUBSCRIPTION_ORG_ID
    [ -z "${SUBSCRIPTION_ORG_ID}" ] && { print_error "Organization ID is required"; exit 1; }
fi
if [ -z "${SUBSCRIPTION_ACTIVATION_KEY:-}" ]; then
    read -r -s -p "Activation key: " SUBSCRIPTION_ACTIVATION_KEY
    echo ""
    [ -z "${SUBSCRIPTION_ACTIVATION_KEY}" ] && { print_error "Activation key is required"; exit 1; }
fi
export SUBSCRIPTION_ORG_ID SUBSCRIPTION_ACTIVATION_KEY

# Substitute and apply VM template
print_step "Applying rhel-webserver-vm.yaml..."
envsubst '$SUBSCRIPTION_ORG_ID $SUBSCRIPTION_ACTIVATION_KEY' < "${VM_TEMPLATE}" | oc apply -f -

print_info "✓ VM rhel-webserver applied"
echo ""
print_info "Connect: virtctl console rhel-webserver -n default"
print_info "Login: cloud-user / redhat"
echo ""
