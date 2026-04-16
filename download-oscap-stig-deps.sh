#!/usr/bin/env bash
# ==============================================================================
# download-oscap-stig-deps.sh
#
# Downloads all RPM packages, Ansible collections, and optional Python wheels
# needed to run any oscap-generated XCCDF Ansible remediation playbook
# (STIG, CIS, PCI-DSS, HIPAA, etc.) on an air-gapped RHEL 8 machine.
#
# Run this script on an internet-connected RHEL 8 system with an active Red Hat
# subscription (or compatible: CentOS Stream 8, AlmaLinux 8, Rocky Linux 8).
#
# Required repositories:
#   rhel-8-for-x86_64-baseos-rpms
#   rhel-8-for-x86_64-appstream-rpms
#
# Usage:
#   bash download-oscap-stig-deps.sh
#
# Environment variable overrides:
#   OUTPUT_BASE_DIR   Where to stage downloaded files  (default: ./oscap-stig-deps)
#   RHEL_MAJOR        Major RHEL version to target      (default: 8)
#   ARCH              CPU architecture                  (default: x86_64)
#   PYTHON_VERSION    CPython version for pip wheels    (default: 38)
# ==============================================================================
set -euo pipefail

# ── CONFIGURATION ──────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.0.0"
OUTPUT_BASE_DIR="${OUTPUT_BASE_DIR:-./oscap-stig-deps}"
RHEL_MAJOR="${RHEL_MAJOR:-8}"
ARCH="${ARCH:-x86_64}"
# RHEL 8 ships Python 3.8 by default; adjust if using a Python 3.9 AppStream module
PYTHON_VERSION="${PYTHON_VERSION:-38}"

# RPM packages to download with full transitive dependency resolution.
# --alldeps ensures packages already installed on this host are still fetched,
# so the bundle is complete for a fresh air-gapped VM.
RPM_PACKAGES=(
    openscap
    openscap-scanner
    openscap-utils
    scap-security-guide
    ansible-core
    python3
    python3-pip
    python3-jinja2
    python3-pyyaml
    python3-cryptography
    python3-paramiko
    python3-resolvelib
    python3-packaging
    sshpass
    dnf-plugins-core
    createrepo_c
)

# Ansible Galaxy collections required by oscap/scap-security-guide-generated
# playbooks. ansible.posix and community.general cover all SSG RHEL 8 profiles.
# Add extra collections here for custom or third-party XCCDF content.
COLLECTIONS=(
    "ansible.posix"
    "community.general"
)

# Optional pip-only packages (downloaded as manylinux wheels).
# Remove entries or leave empty to skip this phase.
PIP_PACKAGES=(
    "ansible-lint"
)

# ── LOGGING ────────────────────────────────────────────────────────────────────
LOG_FILE="${OUTPUT_BASE_DIR}/download.log"

log()  { printf '[%s] [INFO]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[%s] [WARN]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { printf '[%s] [ERROR] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

# ── PHASE 0: PREFLIGHT ─────────────────────────────────────────────────────────
preflight_checks() {
    log "=== Phase 0: Preflight checks ==="

    # Ensure we are on a RHEL-family system
    if [[ ! -f /etc/redhat-release ]]; then
        die "This script must run on a RHEL/CentOS/AlmaLinux/Rocky ${RHEL_MAJOR} system."
    fi
    local os_ver
    os_ver=$(grep -oP '\d+' /etc/redhat-release | head -1)
    if [[ "${os_ver}" != "${RHEL_MAJOR}" ]]; then
        warn "Expected RHEL ${RHEL_MAJOR}, detected major version ${os_ver} — proceeding with caution."
    fi

    # Verify required tools are present
    local required_tools=(dnf sha256sum tar)
    for tool in "${required_tools[@]}"; do
        command -v "$tool" &>/dev/null \
            || die "Required tool not found: '${tool}'. Install it before running this script."
    done

    # ansible-galaxy and pip3 are needed for collection/wheel downloads but may
    # not be installed yet; install them via dnf if missing.
    if ! command -v ansible-galaxy &>/dev/null; then
        log "ansible-galaxy not found — installing ansible-core via dnf..."
        dnf install -y ansible-core 2>&1 | tee -a "$LOG_FILE" \
            || die "Failed to install ansible-core. Ensure AppStream repo is enabled."
    fi

    if ! command -v pip3 &>/dev/null; then
        log "pip3 not found — installing python3-pip via dnf..."
        dnf install -y python3-pip 2>&1 | tee -a "$LOG_FILE" \
            || die "Failed to install python3-pip."
    fi

    # Ensure dnf-plugins-core is present (provides 'dnf download')
    if ! rpm -q dnf-plugins-core &>/dev/null; then
        log "dnf-plugins-core not found — installing..."
        dnf install -y dnf-plugins-core 2>&1 | tee -a "$LOG_FILE" \
            || die "Failed to install dnf-plugins-core."
    fi

    # Warn if expected RHEL 8 repos are not enabled (non-fatal: CentOS/Alma/Rocky
    # use different repo names but carry equivalent packages)
    local required_repos=(
        "rhel-${RHEL_MAJOR}-for-${ARCH}-baseos-rpms"
        "rhel-${RHEL_MAJOR}-for-${ARCH}-appstream-rpms"
    )
    for repo in "${required_repos[@]}"; do
        if ! dnf repolist enabled 2>/dev/null | grep -q "$repo"; then
            warn "Repository '${repo}' not in enabled list."
            warn "Enable with: subscription-manager repos --enable ${repo}"
            warn "CentOS/AlmaLinux/Rocky equivalents are also acceptable."
        fi
    done

    # Rough disk space check: full dep tree is typically 1.5–3 GB; warn at 5 GB
    local avail_kb
    avail_kb=$(df -k "$(dirname "$OUTPUT_BASE_DIR")" 2>/dev/null | awk 'NR==2{print $4}' || echo 0)
    if (( avail_kb > 0 && avail_kb < 5242880 )); then
        warn "Available disk space (~$((avail_kb / 1024)) MB) may be insufficient; 5 GB+ recommended."
    fi

    log "Preflight checks complete."
}

# ── PHASE 1: DIRECTORY SETUP ───────────────────────────────────────────────────
setup_directories() {
    log "=== Phase 1: Creating directory structure ==="
    mkdir -p \
        "${OUTPUT_BASE_DIR}/rpms" \
        "${OUTPUT_BASE_DIR}/collections" \
        "${OUTPUT_BASE_DIR}/python-pkgs"
    log "Directories created under: ${OUTPUT_BASE_DIR}"
}

# ── PHASE 2: DOWNLOAD RPMs ─────────────────────────────────────────────────────
download_rpms() {
    log "=== Phase 2: Downloading RPMs ==="
    log "Packages: ${RPM_PACKAGES[*]}"

    # Expire the dnf cache so we get the latest metadata
    dnf clean expire-cache 2>&1 | tee -a "$LOG_FILE" || true

    # --resolve  : include all dependencies
    # --alldeps  : include deps even if already installed on this host (critical
    #              for producing a complete bundle for a fresh air-gapped VM)
    dnf download \
        --resolve \
        --alldeps \
        --arch="${ARCH}" \
        --downloaddir="${OUTPUT_BASE_DIR}/rpms" \
        "${RPM_PACKAGES[@]}" \
        2>&1 | tee -a "$LOG_FILE"

    local rpm_count
    rpm_count=$(find "${OUTPUT_BASE_DIR}/rpms" -name '*.rpm' | wc -l)
    log "Downloaded ${rpm_count} RPM file(s) to ${OUTPUT_BASE_DIR}/rpms/"
    (( rpm_count > 0 )) || die "No RPMs downloaded — check repository access and package names."
}

# ── PHASE 3: DOWNLOAD ANSIBLE COLLECTIONS ─────────────────────────────────────
download_collections() {
    log "=== Phase 3: Downloading Ansible collections ==="

    # Write the input requirements file
    local req_file="${OUTPUT_BASE_DIR}/collections-requirements-input.yml"
    {
        printf -- '---\ncollections:\n'
        for col in "${COLLECTIONS[@]}"; do
            printf '  - name: %s\n' "$col"
        done
    } > "$req_file"
    log "Collection requirements file: ${req_file}"

    # 'ansible-galaxy collection download' resolves transitive collection deps
    # and writes a requirements.yml into the dest dir referencing local tarballs.
    # That generated requirements.yml is used by the install script.
    ansible-galaxy collection download \
        -r "$req_file" \
        -p "${OUTPUT_BASE_DIR}/collections" \
        2>&1 | tee -a "$LOG_FILE"

    local col_count
    col_count=$(find "${OUTPUT_BASE_DIR}/collections" -name '*.tar.gz' | wc -l)
    log "Downloaded ${col_count} collection archive(s)."
    (( col_count > 0 )) || die "No collections downloaded — check ansible-galaxy connectivity."

    # The auto-generated requirements.yml is required for offline install
    if [[ ! -f "${OUTPUT_BASE_DIR}/collections/requirements.yml" ]]; then
        die "ansible-galaxy did not produce collections/requirements.yml — offline install will fail."
    fi
    log "Generated requirements.yml verified."
}

# ── PHASE 4: DOWNLOAD PYTHON WHEELS (OPTIONAL) ────────────────────────────────
download_python_pkgs() {
    log "=== Phase 4: Downloading Python wheels ==="

    if (( ${#PIP_PACKAGES[@]} == 0 )); then
        log "PIP_PACKAGES list is empty — skipping Python wheel download."
        return 0
    fi

    log "Packages: ${PIP_PACKAGES[*]}"

    # --platform / --python-version / --implementation pin the wheels to
    # RHEL 8's default CPython 3.8 on x86_64, regardless of what Python
    # version is running on this download host.
    if pip3 download \
            --dest "${OUTPUT_BASE_DIR}/python-pkgs" \
            --only-binary=:all: \
            --platform manylinux2014_x86_64 \
            --python-version "${PYTHON_VERSION}" \
            --implementation cp \
            "${PIP_PACKAGES[@]}" \
            2>&1 | tee -a "$LOG_FILE"; then
        log "Binary wheel download succeeded."
    else
        warn "Binary-only download failed for one or more packages; retrying without --only-binary..."
        pip3 download \
            --dest "${OUTPUT_BASE_DIR}/python-pkgs" \
            --platform manylinux2014_x86_64 \
            --python-version "${PYTHON_VERSION}" \
            --implementation cp \
            "${PIP_PACKAGES[@]}" \
            2>&1 | tee -a "$LOG_FILE" \
        || warn "Python wheel download failed — python-pkgs/ may be incomplete."
    fi

    local pkg_count
    pkg_count=$(find "${OUTPUT_BASE_DIR}/python-pkgs" \( -name '*.whl' -o -name '*.tar.gz' \) | wc -l)
    log "Downloaded ${pkg_count} Python package file(s)."
}

# ── PHASE 5: GENERATE SHA256 MANIFEST ─────────────────────────────────────────
generate_manifest() {
    log "=== Phase 5: Generating SHA256 manifest ==="

    local manifest="${OUTPUT_BASE_DIR}/manifest.sha256"
    find "${OUTPUT_BASE_DIR}" -type f \
        ! -name 'manifest.sha256' \
        ! -name 'download.log' \
        | sort \
        | xargs sha256sum \
        > "$manifest"

    local count
    count=$(wc -l < "$manifest")
    log "Manifest written (${count} files): ${manifest}"
}

# ── PHASE 6: WRITE TRANSFER INFO ──────────────────────────────────────────────
write_transfer_info() {
    local rpm_count col_count pkg_count
    rpm_count=$(find "${OUTPUT_BASE_DIR}/rpms"        -name '*.rpm'                                     | wc -l)
    col_count=$(find "${OUTPUT_BASE_DIR}/collections" -name '*.tar.gz'                                  | wc -l)
    pkg_count=$(find "${OUTPUT_BASE_DIR}/python-pkgs" \( -name '*.whl' -o -name '*.tar.gz' \)           | wc -l)

    cat > "${OUTPUT_BASE_DIR}/transfer-info.txt" <<EOF
oscap-stig-deps Transfer Package
=================================
Generated    : $(date '+%Y-%m-%d %H:%M:%S %Z')
Script ver.  : ${SCRIPT_VERSION}
Source host  : $(hostname -f 2>/dev/null || hostname)
RHEL major   : ${RHEL_MAJOR}
Architecture : ${ARCH}
Ansible ver. : $(ansible --version 2>/dev/null | head -1 || echo "unknown")

RPM packages requested:
$(printf '  - %s\n' "${RPM_PACKAGES[@]}")

Ansible collections:
$(printf '  - %s\n' "${COLLECTIONS[@]}")

Python packages:
$(printf '  - %s\n' "${PIP_PACKAGES[@]:-none}")

File counts:
  RPMs            : ${rpm_count}
  Collections     : ${col_count}
  Python packages : ${pkg_count}

Install instructions: see install-oscap-stig-deps.sh (included in tarball)
EOF
    log "Transfer info written to: ${OUTPUT_BASE_DIR}/transfer-info.txt"
}

# ── PHASE 7: PACKAGE INTO TARBALL ─────────────────────────────────────────────
package_tarball() {
    log "=== Phase 7: Packaging transfer tarball ==="

    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local tarball_name="oscap-stig-deps-${ts}.tar.gz"
    local tarball_path
    tarball_path="$(cd "$(dirname "${OUTPUT_BASE_DIR}")" && pwd)/${tarball_name}"

    # Bundle the install script alongside the downloaded files if it exists
    local install_script
    install_script="$(dirname "$(realpath "$0")")/install-oscap-stig-deps.sh"
    if [[ -f "$install_script" ]]; then
        cp "$install_script" "${OUTPUT_BASE_DIR}/install-oscap-stig-deps.sh"
        log "Bundled install-oscap-stig-deps.sh into the package."
    else
        warn "install-oscap-stig-deps.sh not found alongside this script — not bundled."
        warn "Copy it to the air-gapped machine manually."
    fi

    tar -czf "$tarball_path" \
        -C "$(dirname "${OUTPUT_BASE_DIR}")" \
        "$(basename "${OUTPUT_BASE_DIR}")" \
        2>&1 | tee -a "$LOG_FILE"

    sha256sum "$tarball_path" > "${tarball_path}.sha256"

    log "============================================================"
    log "  Transfer package ready"
    log "  Tarball : ${tarball_path}"
    log "  SHA256  : ${tarball_path}.sha256"
    log ""
    log "  Transfer BOTH files to the air-gapped machine, then:"
    log ""
    log "    # Verify integrity"
    log "    sha256sum -c ${tarball_name}.sha256"
    log ""
    log "    # Extract"
    log "    tar -xzf ${tarball_name}"
    log ""
    log "    # Install (as root)"
    log "    cd oscap-stig-deps"
    log "    sudo bash install-oscap-stig-deps.sh"
    log "============================================================"
}

# ── MAIN ───────────────────────────────────────────────────────────────────────
main() {
    # Create the output dir early so the log file has somewhere to live
    mkdir -p "${OUTPUT_BASE_DIR}"

    log "============================================================"
    log "  OpenSCAP STIG Dependency Downloader v${SCRIPT_VERSION}"
    log "============================================================"

    preflight_checks
    setup_directories
    download_rpms
    download_collections
    download_python_pkgs
    generate_manifest
    write_transfer_info
    package_tarball

    log "=== Download phase complete. ==="
    log "Log file: ${LOG_FILE}"
}

main "$@"
