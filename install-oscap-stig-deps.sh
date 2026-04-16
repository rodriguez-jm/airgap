#!/usr/bin/env bash
# ==============================================================================
# install-oscap-stig-deps.sh
#
# Installs the RPM packages required to run playbook.yml on an air-gapped
# RHEL 8 machine. This script consumes the bundle produced by
# download-oscap-stig-deps.sh.
#
# Packages installed:
#   - aide                        (file integrity monitoring — DISA STIG requirement)
#   - policycoreutils-python-utils (SELinux policy management)
#   - python3-libselinux           (Python SELinux bindings for Ansible SELinux tasks)
#   - python3-policycoreutils      (Python SELinux policy utilities)
#
# Assumptions:
#   - The air-gapped machine already has Ansible and Python 3.12 installed.
#   - No internet access is available on this machine.
#   - This script is run from inside the extracted oscap-stig-deps/ directory.
#
# Usage:
#   sudo bash install-oscap-stig-deps.sh
#
# Environment variable overrides:
#   DEPS_DIR   Path to the extracted bundle directory  (default: script's directory)
# ==============================================================================
set -euo pipefail

# ── CONFIGURATION ──────────────────────────────────────────────────────────────
SCRIPT_VERSION="2.0.0"
DEPS_DIR="${DEPS_DIR:-$(dirname "$(realpath "$0")")}"

# Packages the playbook installs — used for targeted verification after install
PLAYBOOK_PACKAGES=(
    aide
    fapolicyd
    mailx
    opensc
    postfix
    policycoreutils-python-utils
    python3-libselinux
    python3-policycoreutils
)

# ── LOGGING ────────────────────────────────────────────────────────────────────
LOG_FILE="${DEPS_DIR}/install.log"

log()  { printf '[%s] [INFO]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[%s] [WARN]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { printf '[%s] [ERROR] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

# ── PHASE 0: PREFLIGHT ─────────────────────────────────────────────────────────
preflight_checks() {
    log "=== Phase 0: Preflight checks ==="

    [[ "$(id -u)" == "0" ]] || die "Must be run as root (use: sudo bash $0)."

    if [[ ! -f /etc/redhat-release ]]; then
        die "This script must run on a RHEL/CentOS/AlmaLinux/Rocky 8 system."
    fi
    local os_ver
    os_ver=$(grep -oP '\d+' /etc/redhat-release | head -1)
    if [[ "${os_ver}" != "8" ]]; then
        warn "Expected RHEL 8, detected major version ${os_ver} — proceeding with caution."
    fi

    [[ -d "${DEPS_DIR}/rpms" ]] \
        || die "RPM directory not found: ${DEPS_DIR}/rpms — is DEPS_DIR set correctly?"

    local rpm_count
    rpm_count=$(find "${DEPS_DIR}/rpms" -name '*.rpm' | wc -l)
    (( rpm_count > 0 )) || die "No RPM files found in ${DEPS_DIR}/rpms."
    log "Found ${rpm_count} RPM file(s) in bundle."

    # Verify file integrity against the download manifest
    if [[ -f "${DEPS_DIR}/manifest.sha256" ]]; then
        log "Verifying bundle integrity..."
        pushd "${DEPS_DIR}" > /dev/null
        if sha256sum -c manifest.sha256 --quiet 2>&1 | tee -a "$LOG_FILE"; then
            log "Integrity check PASSED."
        else
            die "Integrity check FAILED — files may be corrupted. Re-transfer the bundle and retry."
        fi
        popd > /dev/null
    else
        warn "manifest.sha256 not found — skipping integrity check."
    fi

    log "Preflight checks complete."
}

# ── PHASE 1: BUILD LOCAL DNF REPOSITORY ───────────────────────────────────────
build_local_repo() {
    log "=== Phase 1: Building local DNF repository ==="

    local rpm_dir="${DEPS_DIR}/rpms"

    # createrepo_c is included in the bundle; bootstrap it with rpm --nodeps
    # before using it to generate metadata for everything else.
    if ! command -v createrepo_c &>/dev/null; then
        log "Bootstrapping createrepo_c from bundle..."
        local cr_pkgs=()
        while IFS= read -r f; do cr_pkgs+=("$f"); done < <(
            find "${rpm_dir}" \
                -name 'createrepo_c-[0-9]*.rpm' \
                -o -name 'createrepo_c-libs-*.rpm' \
                -o -name 'python3-createrepo_c-*.rpm' \
                2>/dev/null | sort
        )
        if (( ${#cr_pkgs[@]} > 0 )); then
            rpm -Uvh --nodeps "${cr_pkgs[@]}" 2>&1 | tee -a "$LOG_FILE" || true
        else
            warn "createrepo_c RPMs not found in bundle — will use fallback install method."
        fi
    fi

    if command -v createrepo_c &>/dev/null; then
        log "Generating repodata for local repository..."
        createrepo_c "${rpm_dir}" 2>&1 | tee -a "$LOG_FILE"
        log "Local repo metadata ready: ${rpm_dir}/repodata/"
    else
        warn "createrepo_c unavailable — will fall back to 'dnf install *.rpm'."
    fi
}

# ── PHASE 2: INSTALL RPMs ──────────────────────────────────────────────────────
install_rpms() {
    log "=== Phase 2: Installing packages ==="

    local rpm_dir="${DEPS_DIR}/rpms"

    if [[ -d "${rpm_dir}/repodata" ]]; then
        log "Installing via dnf with local repodata (preferred)..."
        # --disablerepo='*'    : no network repo access
        # --repofrompath       : use our local RPM directory as the sole repo
        # --setopt gpgcheck=0  : RPMs were integrity-checked via manifest.sha256
        dnf install \
            --disablerepo='*' \
            --repofrompath="local-oscap-stig,${rpm_dir}" \
            --repo='local-oscap-stig' \
            --setopt=local-oscap-stig.gpgcheck=0 \
            -y \
            "${PLAYBOOK_PACKAGES[@]}" \
            2>&1 | tee -a "$LOG_FILE"
    else
        log "Installing via dnf install on RPM files (fallback)..."
        # shellcheck disable=SC2046
        dnf install \
            --disablerepo='*' \
            -y \
            $(find "${rpm_dir}" -name '*.rpm' ! -name '*debuginfo*') \
            2>&1 | tee -a "$LOG_FILE"
    fi

    log "Package installation complete."
}

# ── PHASE 3: POST-INSTALL VERIFICATION ────────────────────────────────────────
verify_installation() {
    log "=== Phase 3: Verifying installation ==="

    local errors=0

    for pkg in "${PLAYBOOK_PACKAGES[@]}"; do
        if rpm -q "$pkg" &>/dev/null; then
            log "  [OK]   ${pkg} $(rpm -q --qf '%{VERSION}-%{RELEASE}' "$pkg")"
        else
            warn "  [FAIL] ${pkg} — not installed."
            (( errors++ )) || true
        fi
    done

    # Verify the aide binary is executable
    if command -v aide &>/dev/null; then
        log "  [OK]   aide binary: $(command -v aide)"
    else
        warn "  [FAIL] aide binary not found in PATH."
        (( errors++ )) || true
    fi

    log ""
    if (( errors == 0 )); then
        log "=== All verification checks PASSED ==="
    else
        warn "=== ${errors} check(s) FAILED — review the log: ${LOG_FILE} ==="
    fi

    return "${errors}"
}

# ── PHASE 4: PRINT USAGE ──────────────────────────────────────────────────────
print_usage() {
    log ""
    log "============================================================"
    log "  Installation complete — how to run the STIG playbook"
    log "============================================================"
    log ""
    log "  # Copy playbook.yml to this machine, then run:"
    log ""
    log "  # Dry-run (check mode — no changes applied):"
    log "  ansible-playbook -i 'localhost,' -c local --check playbook.yml"
    log ""
    log "  # Apply all remediations:"
    log "  ansible-playbook -i 'localhost,' -c local playbook.yml"
    log ""
    log "  # Against a remote host:"
    log "  ansible-playbook -i '192.168.1.155,' playbook.yml"
    log ""
    log "  NOTE: The playbook uses only ansible.builtin.* modules."
    log "        No Ansible collections need to be installed."
    log "============================================================"
    log ""
    log "Install log: ${LOG_FILE}"
}

# ── MAIN ───────────────────────────────────────────────────────────────────────
main() {
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

    log "============================================================"
    log "  OpenSCAP STIG Dependency Installer v${SCRIPT_VERSION}"
    log "  Bundle: ${DEPS_DIR}"
    log "============================================================"

    preflight_checks
    build_local_repo
    install_rpms
    verify_installation
    print_usage

    log "=== Install complete. ==="
}

main "$@"
