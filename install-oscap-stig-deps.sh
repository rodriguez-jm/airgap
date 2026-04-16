#!/usr/bin/env bash
# ==============================================================================
# install-oscap-stig-deps.sh
#
# Installs all RPM packages, Ansible collections, and optional Python wheels
# from a bundle produced by download-oscap-stig-deps.sh onto an air-gapped
# RHEL 8 machine.
#
# Must be run as root on the air-gapped target VM.
#
# Usage:
#   sudo bash install-oscap-stig-deps.sh
#
# The script expects to be run from within the extracted bundle directory
# (oscap-stig-deps/) that contains rpms/, collections/, and python-pkgs/.
#
# Environment variable overrides:
#   DEPS_DIR             Path to the extracted bundle   (default: script's directory)
#   COLLECTIONS_PATH     Ansible collections install path
#                        (default: /usr/share/ansible/collections)
#   INSTALL_PIP_PKGS     Set to "false" to skip pip installs (default: true)
# ==============================================================================
set -euo pipefail

# ── CONFIGURATION ──────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.0.0"
DEPS_DIR="${DEPS_DIR:-$(dirname "$(realpath "$0")")}"
COLLECTIONS_PATH="${COLLECTIONS_PATH:-/usr/share/ansible/collections}"
INSTALL_PIP_PKGS="${INSTALL_PIP_PKGS:-true}"

# ── LOGGING ────────────────────────────────────────────────────────────────────
LOG_FILE="${DEPS_DIR}/install.log"

log()  { printf '[%s] [INFO]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[%s] [WARN]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { printf '[%s] [ERROR] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

# ── PHASE 0: PREFLIGHT ─────────────────────────────────────────────────────────
preflight_checks() {
    log "=== Phase 0: Preflight checks ==="

    # Must run as root
    [[ "$(id -u)" == "0" ]] || die "This script must be run as root (use: sudo bash $0)."

    # Must be on RHEL 8 family
    if [[ ! -f /etc/redhat-release ]]; then
        die "This script must run on a RHEL/CentOS/AlmaLinux/Rocky 8 system."
    fi
    local os_ver
    os_ver=$(grep -oP '\d+' /etc/redhat-release | head -1)
    if [[ "${os_ver}" != "8" ]]; then
        warn "Expected RHEL 8, detected major version ${os_ver} — proceeding with caution."
    fi

    # Verify expected bundle directories exist
    for subdir in rpms collections; do
        [[ -d "${DEPS_DIR}/${subdir}" ]] \
            || die "Expected directory '${DEPS_DIR}/${subdir}' not found. Is DEPS_DIR set correctly?"
    done

    # Verify file integrity against the manifest (if present)
    if [[ -f "${DEPS_DIR}/manifest.sha256" ]]; then
        log "Verifying file integrity..."
        # sha256sum -c expects paths relative to where it's run, so cd first
        pushd "${DEPS_DIR}" > /dev/null
        if sha256sum -c manifest.sha256 --quiet 2>&1 | tee -a "$LOG_FILE"; then
            log "Integrity check PASSED."
        else
            die "Integrity check FAILED — files may be corrupted. Re-transfer the bundle and retry."
        fi
        popd > /dev/null
    else
        warn "manifest.sha256 not found — skipping integrity verification."
    fi

    log "Preflight checks complete."
}

# ── PHASE 1: BUILD LOCAL DNF REPOSITORY ───────────────────────────────────────
build_local_repo() {
    log "=== Phase 1: Building local DNF repository metadata ==="

    local rpm_dir="${DEPS_DIR}/rpms"

    # createrepo_c should be in the bundle; bootstrap it with rpm --nodeps
    # before using it to generate metadata for all the other packages.
    if ! command -v createrepo_c &>/dev/null; then
        log "createrepo_c not yet installed — attempting bootstrap install..."
        local crpkg
        crpkg=$(find "${rpm_dir}" -name 'createrepo_c-[0-9]*.rpm' ! -name '*debuginfo*' | sort -V | tail -1)
        if [[ -n "${crpkg}" ]]; then
            # Install createrepo_c and its direct lib deps without requiring
            # a full dependency graph (they are all present in the bundle)
            local cr_libs=()
            while IFS= read -r f; do cr_libs+=("$f"); done \
                < <(find "${rpm_dir}" -name 'python3-createrepo_c-*.rpm' \
                                     -o -name 'createrepo_c-libs-*.rpm' 2>/dev/null || true)
            rpm -Uvh --nodeps "${crpkg}" "${cr_libs[@]}" 2>&1 | tee -a "$LOG_FILE" || true
        else
            warn "createrepo_c RPM not found in bundle — will fall back to rpm glob install."
        fi
    fi

    if command -v createrepo_c &>/dev/null; then
        log "Running createrepo_c to generate repodata..."
        createrepo_c "${rpm_dir}" 2>&1 | tee -a "$LOG_FILE"
        log "Local repository metadata created at: ${rpm_dir}/repodata/"
    else
        warn "createrepo_c unavailable — will install RPMs via 'dnf install *.rpm' fallback."
    fi
}

# ── PHASE 2: INSTALL RPMs ──────────────────────────────────────────────────────
install_rpms() {
    log "=== Phase 2: Installing RPMs ==="

    local rpm_dir="${DEPS_DIR}/rpms"
    local rpm_count
    rpm_count=$(find "${rpm_dir}" -name '*.rpm' ! -name '*debuginfo*' | wc -l)
    log "Found ${rpm_count} RPM file(s) in ${rpm_dir}."
    (( rpm_count > 0 )) || die "No RPMs found in ${rpm_dir} — bundle may be corrupt."

    if [[ -d "${rpm_dir}/repodata" ]]; then
        log "Using dnf with local repodata (preferred method)..."
        # --disablerepo='*'         : block any network repo access
        # --repofrompath            : point dnf at our local directory
        # --repo=local-oscap        : only use our local repo
        # Explicitly list packages so dnf resolves the install order correctly
        dnf install \
            --disablerepo='*' \
            --repofrompath="local-oscap,${rpm_dir}" \
            --repo='local-oscap' \
            --setopt=local-oscap.gpgcheck=0 \
            -y \
            openscap \
            openscap-scanner \
            openscap-utils \
            scap-security-guide \
            ansible-core \
            python3 \
            python3-pip \
            python3-jinja2 \
            python3-pyyaml \
            python3-cryptography \
            python3-paramiko \
            python3-resolvelib \
            python3-packaging \
            sshpass \
            createrepo_c \
            2>&1 | tee -a "$LOG_FILE"
    else
        log "Falling back to 'dnf install *.rpm'..."
        # dnf still handles dependency ordering when given a glob of local RPMs
        # shellcheck disable=SC2046
        dnf install \
            --disablerepo='*' \
            -y \
            $(find "${rpm_dir}" -name '*.rpm' ! -name '*debuginfo*') \
            2>&1 | tee -a "$LOG_FILE"
    fi

    log "RPM installation complete."
}

# ── PHASE 3: INSTALL ANSIBLE COLLECTIONS ──────────────────────────────────────
install_collections() {
    log "=== Phase 3: Installing Ansible collections ==="

    local col_dir="${DEPS_DIR}/collections"

    [[ -f "${col_dir}/requirements.yml" ]] \
        || die "'${col_dir}/requirements.yml' not found. Was download-oscap-stig-deps.sh run correctly?"

    mkdir -p "${COLLECTIONS_PATH}"

    # ansible-galaxy resolves tarball paths relative to requirements.yml, so we
    # must run the command from inside the collections directory.
    pushd "${col_dir}" > /dev/null
    log "Installing from: ${col_dir}/requirements.yml"
    log "Installing to  : ${COLLECTIONS_PATH}"

    ansible-galaxy collection install \
        -r requirements.yml \
        -p "${COLLECTIONS_PATH}" \
        --offline \
        2>&1 | tee -a "$LOG_FILE"

    popd > /dev/null

    log "Collections installed."
    ansible-galaxy collection list 2>/dev/null | tee -a "$LOG_FILE" || true
}

# ── PHASE 4: INSTALL PYTHON PACKAGES (OPTIONAL) ───────────────────────────────
install_python_pkgs() {
    log "=== Phase 4: Installing Python packages ==="

    local pkg_dir="${DEPS_DIR}/python-pkgs"
    local pkg_count
    pkg_count=$(find "${pkg_dir}" \( -name '*.whl' -o -name '*.tar.gz' \) 2>/dev/null | wc -l)

    if (( pkg_count == 0 )); then
        log "No Python packages found in ${pkg_dir} — skipping."
        return 0
    fi

    log "Installing ${pkg_count} Python package file(s)..."

    # --no-index     : do not query PyPI
    # --find-links   : look for packages in our local directory
    # --no-deps      : all deps were pre-resolved during download
    pip3 install \
        --no-index \
        --find-links="${pkg_dir}" \
        --no-deps \
        $(find "${pkg_dir}" -name '*.whl' -printf '%f\n' \
            | sed -E 's/-[0-9][^-]*-[^-]*-[^-]*\.whl$//; s/-/_/g') \
        2>&1 | tee -a "$LOG_FILE" \
    || warn "pip install failed for some packages — review the log for details."
}

# ── PHASE 5: POST-INSTALL VERIFICATION ────────────────────────────────────────
verify_installation() {
    log "=== Phase 5: Verifying installation ==="

    local errors=0

    check_cmd() {
        local cmd="$1" label="${2:-$1}"
        if command -v "$cmd" &>/dev/null; then
            local ver
            ver=$("$cmd" --version 2>&1 | head -1)
            log "  [OK]   ${label}: ${ver}"
        else
            warn "  [FAIL] ${label} not found after installation."
            (( errors++ )) || true
        fi
    }

    check_cmd oscap            "OpenSCAP (oscap)"
    check_cmd ansible          "Ansible"
    check_cmd ansible-playbook "ansible-playbook"
    check_cmd python3          "Python 3"

    # Check SCAP content (installed by scap-security-guide)
    local ssg_ds="/usr/share/xml/scap/ssg/content/ssg-rhel8-ds.xml"
    if [[ -f "${ssg_ds}" ]]; then
        log "  [OK]   SCAP data stream: ${ssg_ds}"
    else
        warn "  [FAIL] ${ssg_ds} not found — scap-security-guide may not have installed."
        (( errors++ )) || true
    fi

    # Check pre-built Ansible playbooks shipped with scap-security-guide
    local ssg_ansible_dir="/usr/share/scap-security-guide/ansible"
    if [[ -d "${ssg_ansible_dir}" ]]; then
        local pb_count
        pb_count=$(find "${ssg_ansible_dir}" -name '*.yml' | wc -l)
        log "  [OK]   Pre-built SSG Ansible playbooks: ${pb_count} found in ${ssg_ansible_dir}"
    else
        warn "  [FAIL] ${ssg_ansible_dir} not found."
        (( errors++ )) || true
    fi

    # Check Ansible collections
    for col in "ansible.posix" "community.general"; do
        local ns="${col%%.*}" name="${col##*.}"
        if ansible-galaxy collection list 2>/dev/null | grep -qE "${ns}[[:space:]]+${name}"; then
            log "  [OK]   Ansible collection: ${col}"
        else
            warn "  [FAIL] Ansible collection '${col}' not found after install."
            (( errors++ )) || true
        fi
    done

    log ""
    if (( errors == 0 )); then
        log "=== All verification checks PASSED ==="
    else
        warn "=== ${errors} check(s) FAILED — review the log: ${LOG_FILE} ==="
    fi

    return "${errors}"
}

# ── PHASE 6: PRINT USAGE INSTRUCTIONS ─────────────────────────────────────────
print_usage() {
    log ""
    log "============================================================"
    log "  Installation complete — how to run the STIG playbook"
    log "============================================================"
    log ""
    log "OPTION A — Use a pre-built playbook from scap-security-guide:"
    log ""
    log "  ansible-playbook -i 'localhost,' -c local \\"
    log "    /usr/share/scap-security-guide/ansible/rhel8-playbook-stig.yml"
    log ""
    log "  Other available profiles:"
    log "    ls /usr/share/scap-security-guide/ansible/rhel8-playbook-*.yml"
    log ""
    log "OPTION B — Generate a custom playbook with oscap (any profile):"
    log ""
    log "  # List available profiles:"
    log "  oscap info /usr/share/xml/scap/ssg/content/ssg-rhel8-ds.xml"
    log ""
    log "  # Generate STIG playbook:"
    log "  oscap xccdf generate fix \\"
    log "    --profile xccdf_org.ssgproject.content_profile_stig \\"
    log "    --fix-type ansible \\"
    log "    /usr/share/xml/scap/ssg/content/ssg-rhel8-ds.xml \\"
    log "    > /tmp/rhel8-stig-playbook.yml"
    log ""
    log "  # Dry-run (check mode):"
    log "  ANSIBLE_COLLECTIONS_PATH=${COLLECTIONS_PATH} \\"
    log "    ansible-playbook -i 'localhost,' -c local --check \\"
    log "    /tmp/rhel8-stig-playbook.yml"
    log ""
    log "  # Apply:"
    log "  ANSIBLE_COLLECTIONS_PATH=${COLLECTIONS_PATH} \\"
    log "    ansible-playbook -i 'localhost,' -c local \\"
    log "    /tmp/rhel8-stig-playbook.yml"
    log ""
    log "  Tip: set collections_paths permanently in /etc/ansible/ansible.cfg:"
    log "    [defaults]"
    log "    collections_paths = ${COLLECTIONS_PATH}"
    log "============================================================"
    log ""
    log "Install log: ${LOG_FILE}"
}

# ── MAIN ───────────────────────────────────────────────────────────────────────
main() {
    # Ensure log directory exists before first log call
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true

    log "============================================================"
    log "  OpenSCAP STIG Dependency Installer v${SCRIPT_VERSION}"
    log "============================================================"
    log "Bundle directory: ${DEPS_DIR}"

    preflight_checks
    build_local_repo
    install_rpms
    install_collections

    if [[ "${INSTALL_PIP_PKGS}" == "true" ]]; then
        install_python_pkgs
    else
        log "INSTALL_PIP_PKGS=false — skipping Python package install."
    fi

    verify_installation
    print_usage

    log "=== Install phase complete. ==="
}

main "$@"
