#!/usr/bin/env bash
# export_azure_vm_image.sh
#
# Export an Azure VM or managed image as a VHD for use in air-gapped environments.
#
# Two modes of operation:
#
#   VM mode (--vm-name):
#     1. Deallocate the source VM
#     2. Generalize the VM (sysprep / waagent deprovision)
#     3. Capture a managed image from the VM
#     4. Generate a SAS URL for the image OS disk
#     5. Download the VHD to a local output directory
#
#   Image mode (--image-name only, no --vm-name):
#     Skips steps 1-3; exports the existing managed image directly.
#     1. Generate a SAS URL for the image OS disk
#     2. Download the VHD to a local output directory
#
# Usage:
#   ./export_azure_vm_image.sh [OPTIONS]
#
# Options:
#   -g, --resource-group    Resource group (required)
#   -v, --vm-name           Name of the VM to capture (omit if using an existing image)
#   -i, --image-name        Managed image name to export, or name to give the captured image
#                           (required when --vm-name is set; required when exporting an image)
#   -s, --storage-account   Storage account for staging the export (required)
#   -c, --container         Blob container name for staging (default: vm-exports)
#   -o, --output-dir        Local directory to download the VHD (default: ./output)
#   -l, --location          Azure region (defaults to resource's region)
#   -r, --retention-hours   SAS token validity in hours (default: 4)
#   -n, --no-download       Skip downloading; only print the SAS URL
#   -k, --keep-image        Keep the managed image after export (default: delete)
#   -h, --help              Show this help message
#
# Prerequisites:
#   - Azure CLI (az) installed and logged in
#   - azcopy installed (unless --no-download is set)
#   - VM mode: the VM must be generalizable (Linux with waagent, Windows with sysprep)
#
# Examples:
#   # Export an existing managed image
#   ./export_azure_vm_image.sh \
#       --resource-group my-rg \
#       --image-name my-existing-image \
#       --storage-account mystorageacct \
#       --output-dir /mnt/usb/images
#
#   # Capture a VM and export it
#   ./export_azure_vm_image.sh \
#       --resource-group my-rg \
#       --vm-name my-vm \
#       --image-name my-vm-image-$(date +%Y%m%d) \
#       --storage-account mystorageacct \
#       --output-dir /mnt/usb/images

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
RESOURCE_GROUP=""
VM_NAME=""
IMAGE_NAME=""
STORAGE_ACCOUNT=""
CONTAINER="vm-exports"
OUTPUT_DIR="./output"
LOCATION=""
RETENTION_HOURS=4
NO_DOWNLOAD=false
KEEP_IMAGE=false

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] INFO  $*"; }
warn() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] WARN  $*" >&2; }
die()  { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ERROR $*" >&2; exit 1; }

usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

require_cmd() {
    command -v "$1" &>/dev/null || die "'$1' is not installed or not in PATH."
}

confirm() {
    local prompt="$1"
    read -rp "$prompt [y/N] " ans
    [[ "${ans,,}" == "y" ]] || die "Aborted by user."
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -g|--resource-group)   RESOURCE_GROUP="$2";   shift 2 ;;
            -v|--vm-name)          VM_NAME="$2";           shift 2 ;;
            -i|--image-name)       IMAGE_NAME="$2";        shift 2 ;;
            -s|--storage-account)  STORAGE_ACCOUNT="$2";  shift 2 ;;
            -c|--container)        CONTAINER="$2";         shift 2 ;;
            -o|--output-dir)       OUTPUT_DIR="$2";        shift 2 ;;
            -l|--location)         LOCATION="$2";          shift 2 ;;
            -r|--retention-hours)  RETENTION_HOURS="$2";  shift 2 ;;
            -n|--no-download)      NO_DOWNLOAD=true;       shift   ;;
            -k|--keep-image)       KEEP_IMAGE=true;        shift   ;;
            -h|--help)             usage ;;
            *) die "Unknown argument: $1. Use --help for usage." ;;
        esac
    done

    [[ -n "$RESOURCE_GROUP"  ]] || die "--resource-group is required."
    [[ -n "$IMAGE_NAME"      ]] || die "--image-name is required."
    [[ -n "$STORAGE_ACCOUNT" ]] || die "--storage-account is required."
}

# ---------------------------------------------------------------------------
# Azure helpers
# ---------------------------------------------------------------------------
get_vm_location() {
    az vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query location \
        --output tsv
}

get_image_location() {
    az image show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IMAGE_NAME" \
        --query location \
        --output tsv
}

get_vm_os_type() {
    az vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query storageProfile.osDisk.osType \
        --output tsv
}

get_vm_power_state() {
    az vm get-instance-view \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
        --output tsv
}

image_exists() {
    az image show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IMAGE_NAME" \
        --output none 2>/dev/null
}

# ---------------------------------------------------------------------------
# VM-mode steps
# ---------------------------------------------------------------------------
step_deallocate() {
    local state
    state=$(get_vm_power_state)
    log "VM power state: $state"

    if [[ "$state" != "VM deallocated" ]]; then
        warn "This will SHUT DOWN and deallocate '$VM_NAME'."
        confirm "Continue?"
        log "Deallocating VM '$VM_NAME'..."
        az vm deallocate \
            --resource-group "$RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --output none
        log "VM deallocated."
    else
        log "VM is already deallocated."
    fi
}

step_generalize() {
    local os_type="$1"
    log "Generalizing VM (OS type: $os_type)..."
    warn "Generalization is DESTRUCTIVE — the VM cannot be restarted afterward."
    confirm "Proceed with generalization?"

    az vm generalize \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --output none
    log "VM generalized."
}

step_capture_image() {
    log "Capturing managed image '$IMAGE_NAME' from VM '$VM_NAME'..."
    az image create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IMAGE_NAME" \
        --source "$VM_NAME" \
        --location "$LOCATION" \
        --output none
    log "Managed image '$IMAGE_NAME' created."
}

# ---------------------------------------------------------------------------
# Shared export steps
# ---------------------------------------------------------------------------
step_get_image_disk_id() {
    az image show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$IMAGE_NAME" \
        --query storageProfile.osDisk.managedDisk.id \
        --output tsv
}

step_generate_sas_url() {
    local disk_id="$1"
    log "Generating SAS URL for disk (valid ${RETENTION_HOURS}h)..."
    local sas_url
    sas_url=$(az disk grant-access \
        --ids "$disk_id" \
        --duration-in-seconds $(( RETENTION_HOURS * 3600 )) \
        --access-level Read \
        --query accessSas \
        --output tsv)
    echo "$sas_url"
}

step_download_vhd() {
    local sas_url="$1"
    local dest_file="$2"

    mkdir -p "$OUTPUT_DIR"

    log "Downloading VHD to '$dest_file'..."
    log "This may take a long time depending on disk size and network speed."

    azcopy copy \
        "$sas_url" \
        "$dest_file" \
        --blob-type PageBlob \
        --recursive=false

    log "Download complete: $dest_file"
}

step_revoke_sas() {
    local disk_id="$1"
    log "Revoking disk SAS access..."
    az disk revoke-access --ids "$disk_id" --output none || warn "Could not revoke SAS — check manually."
}

step_cleanup_image() {
    if [[ "$KEEP_IMAGE" == "false" ]]; then
        log "Deleting managed image '$IMAGE_NAME'..."
        az image delete \
            --resource-group "$RESOURCE_GROUP" \
            --name "$IMAGE_NAME" \
            --output none
        log "Managed image deleted."
    else
        log "Keeping managed image '$IMAGE_NAME' (--keep-image set)."
    fi
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    require_cmd az
    if [[ "$NO_DOWNLOAD" == "false" ]]; then
        require_cmd azcopy
    fi

    az account show --output none 2>/dev/null || die "Not logged into Azure CLI. Run 'az login' first."

    if [[ -n "$VM_NAME" ]]; then
        # ---- VM mode ----
        log "Mode: capture VM '$VM_NAME' then export."

        if [[ -z "$LOCATION" ]]; then
            LOCATION=$(get_vm_location)
            log "Using VM location: $LOCATION"
        fi

        local os_type
        os_type=$(get_vm_os_type)
        log "VM OS type: $os_type"

        step_deallocate
        step_generalize "$os_type"
        step_capture_image
    else
        # ---- Image mode ----
        log "Mode: export existing managed image '$IMAGE_NAME'."

        image_exists || die "Managed image '$IMAGE_NAME' not found in resource group '$RESOURCE_GROUP'."

        if [[ -z "$LOCATION" ]]; then
            LOCATION=$(get_image_location)
            log "Using image location: $LOCATION"
        fi

        # --keep-image is implied — we did not create the image, so never delete it
        KEEP_IMAGE=true
    fi

    local disk_id
    disk_id=$(step_get_image_disk_id)
    log "Image OS disk ID: $disk_id"

    local sas_url
    sas_url=$(step_generate_sas_url "$disk_id")

    if [[ "$NO_DOWNLOAD" == "true" ]]; then
        log "Skipping download (--no-download set)."
        log "SAS URL (expires in ${RETENTION_HOURS}h):"
        echo "$sas_url"
    else
        local dest_file="${OUTPUT_DIR}/${IMAGE_NAME}.vhd"
        step_download_vhd "$sas_url" "$dest_file"
        step_revoke_sas "$disk_id"
        log "Export complete. VHD saved to: $dest_file"
        log "Transfer this file to your air-gapped environment."
    fi

    step_cleanup_image

    log "Done."
}

main "$@"
