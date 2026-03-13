#!/bin/bash

# Script: 02-deploy-sample-vms.sh
# Description: Deploy RHEL webserver VM from template with Red Hat subscription registration
# Requires: RH_USERNAME/RH_PASSWORD for subscription, or --skip-subscription
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
VM_NAMESPACE="${VM_NAMESPACE:-default}"
VM_NAME="${VM_NAME:-rhel-webserver}"
SKIP_SUBSCRIPTION="${SKIP_SUBSCRIPTION:-false}"

# Parse args for credentials
while [[ $# -gt 0 ]]; do
    case $1 in
        --username)
            RH_USERNAME="$2"
            shift 2
            ;;
        --password)
            RH_PASSWORD="$2"
            shift 2
            ;;
        --skip-subscription)
            SKIP_SUBSCRIPTION=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--username USER] [--password PASS] [--skip-subscription]"
            echo ""
            echo "Deploys RHEL webserver VM with cloud-init (httpd, SSH password auth)."
            echo ""
            echo "Options:"
            echo "  --username USER     Red Hat subscription username (or set RH_USERNAME)"
            echo "  --password PASS     Red Hat subscription password (or set RH_PASSWORD)"
            echo "  --skip-subscription Skip subscription registration (manual registration required)"
            echo ""
            echo "Examples:"
            echo "  RH_USERNAME=user@example.com RH_PASSWORD=secret $0"
            echo "  $0 --username user@example.com --password secret"
            echo "  $0 --skip-subscription"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check prerequisites
if ! oc whoami &>/dev/null; then
    print_error "Not connected to OpenShift cluster"
    exit 1
fi

if [ ! -f "${VM_TEMPLATE}" ]; then
    print_error "VM template not found: ${VM_TEMPLATE}"
    exit 1
fi

# Require subscription credentials unless --skip-subscription
if [ "${SKIP_SUBSCRIPTION}" != "true" ]; then
    RH_USERNAME="${RH_USERNAME:-}"
    RH_PASSWORD="${RH_PASSWORD:-}"
    if [ -z "${RH_USERNAME}" ] || [ -z "${RH_PASSWORD}" ]; then
        print_error "Red Hat subscription credentials required for auto-registration"
        echo ""
        print_info "Provide credentials via:"
        echo "  RH_USERNAME=user@example.com RH_PASSWORD=secret $0"
        echo "  $0 --username user@example.com --password secret"
        echo ""
        print_info "Or skip subscription (manual registration in VM):"
        echo "  $0 --skip-subscription"
        exit 1
    fi
fi

print_info "VM: ${VM_NAME} in namespace ${VM_NAMESPACE}"
[ "${SKIP_SUBSCRIPTION}" = "true" ] && print_warn "Subscription: skipped (manual registration required)"
echo ""

# Ensure namespace exists
if ! oc get namespace "${VM_NAMESPACE}" &>/dev/null; then
    print_info "Creating namespace ${VM_NAMESPACE}..."
    oc create namespace "${VM_NAMESPACE}"
fi

# Delete existing VM if present
if oc get vm "${VM_NAME}" -n "${VM_NAMESPACE}" &>/dev/null; then
    print_warn "VM ${VM_NAME} already exists. Deleting for fresh deploy..."
    oc delete vm "${VM_NAME}" -n "${VM_NAMESPACE}" --wait=false || true
    print_info "Waiting for cleanup..."
    sleep 10
fi

# Prepare template with credential substitution
print_step "Preparing VM template..."
TEMP_VM=$(mktemp)
trap "rm -f ${TEMP_VM}" EXIT

if [ "${SKIP_SUBSCRIPTION}" = "true" ]; then
    # Remove rh_subscription block entirely
    sed -e '/^              rh_subscription:/,/^              [a-z]/{
        /^              rh_subscription:/d
        /^                username:/d
        /^                password:/d
        /^                #.*auto_attach/d
    }' "${VM_TEMPLATE}" | grep -v '^[[:space:]]*$' | \
    awk '
        /rh_subscription:/ { skip=1; next }
        skip && /^              [a-z]/ { skip=0 }
        !skip { print }
    ' > "${TEMP_VM}" 2>/dev/null || cp "${VM_TEMPLATE}" "${TEMP_VM}"
    # Simpler: use sed to remove the rh_subscription block
    sed -e '/rh_subscription:/,/^              [a-z_]*:/{
        /rh_subscription:/d
        /username:.*YOUR_REDHAT/d
        /password:.*YOUR_REDHAT/d
    }' "${VM_TEMPLATE}" > "${TEMP_VM}" 2>/dev/null || true
    # More reliable: python or multiline sed
    python3 -c "
import re, sys
content = open('${VM_TEMPLATE}').read()
# Remove rh_subscription block (username, password, optional auto_attach)
content = re.sub(r'\n              rh_subscription:.*?(?=\n              [a-z_]|\n              packages:|\Z)', '\n', content, flags=re.DOTALL)
open('${TEMP_VM}', 'w').write(content)
" 2>/dev/null || cp "${VM_TEMPLATE}" "${TEMP_VM}"
else
    cp "${VM_TEMPLATE}" "${TEMP_VM}"
fi

# Substitute credentials (use @ as sed delimiter to avoid / in paths)
if [ "${SKIP_SUBSCRIPTION}" != "true" ]; then
    # Escape special chars for sed ( & \)
    escape_sed() { printf '%s' "$1" | sed 's/[&\\]/\\&/g'; }
    RH_USERNAME_ESC=$(escape_sed "${RH_USERNAME}")
    RH_PASSWORD_ESC=$(escape_sed "${RH_PASSWORD}")
    sed -i.bak "s@<YOUR_REDHAT_USERNAME>@${RH_USERNAME_ESC}@g" "${TEMP_VM}"
    sed -i.bak "s@<YOUR_REDHAT_PASSWORD>@${RH_PASSWORD_ESC}@g" "${TEMP_VM}"
    rm -f "${TEMP_VM}.bak"
fi

# Check if userData exceeds 2048 bytes - if so, use secret
USERDATA_START=$(grep -n "userData: |-" "${TEMP_VM}" | head -1 | cut -d: -f1)
if [ -n "${USERDATA_START}" ]; then
    # Extract userData (from userData: |- to next top-level key at same indent)
    USERDATA_SIZE=$(awk "NR>=${USERDATA_START}" "${TEMP_VM}" | head -200 | wc -c)
    if [ "${USERDATA_SIZE}" -gt 2048 ]; then
        print_info "Cloud-init exceeds 2048 bytes - using Secret..."
        CLOUD_INIT_SECRET="${VM_NAME}-cloud-init"
        # Extract userData content (lines after userData: |-)
        USERDATA_CONTENT=$(awk "NR>${USERDATA_START} && /^            [^ ]/ {exit} NR>${USERDATA_START}" "${TEMP_VM}" | sed 's/^              //')
        echo "${USERDATA_CONTENT}" | oc create secret generic "${CLOUD_INIT_SECRET}" -n "${VM_NAMESPACE}" \
            --from-file=userdata=/dev/stdin --dry-run=client -o yaml | oc apply -f -
        # Replace cloudInitNoCloud block with userDataSecretRef + networkData
        # Use a Python one-liner to do the replacement in the YAML
        python3 << PYEOF
import yaml
with open('${TEMP_VM}') as f:
    vm = yaml.safe_load(f)
# Find cloudInitNoCloud volume and replace
for vol in vm.get('spec', {}).get('template', {}).get('spec', {}).get('volumes', []):
    if 'cloudInitNoCloud' in vol:
        vol['cloudInitNoCloud'] = {
            'userDataSecretRef': {'name': '${CLOUD_INIT_SECRET}'},
            'networkData': 'version: 2\\nethernets:\\n  enp1s0:\\n    dhcp4: true\\n'
        }
        break
with open('${TEMP_VM}', 'w') as f:
    yaml.dump(vm, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
PYEOF
    fi
fi

# Apply namespace if template uses different one
sed -i.bak "s/namespace: default/namespace: ${VM_NAMESPACE}/g" "${TEMP_VM}" 2>/dev/null || true
rm -f "${TEMP_VM}.bak" 2>/dev/null || true

print_step "Creating VM ${VM_NAME}..."
oc apply -f "${TEMP_VM}"

print_info "✓ VM ${VM_NAME} created and starting"
echo ""
print_info "Cloud-init will:"
print_info "  • Set hostname: rhel-web-01"
print_info "  • Create user: cloud-user / redhat"
print_info "  • Enable SSH password auth"
[ "${SKIP_SUBSCRIPTION}" != "true" ] && print_info "  • Register with Red Hat subscription"
print_info "  • Install httpd, firewalld, curl, vim, git"
print_info "  • Create test page at /var/www/html/index.html"
echo ""
print_info "Connect: virtctl console ${VM_NAME} -n ${VM_NAMESPACE}"
print_info "Login: cloud-user / redhat"
echo ""
