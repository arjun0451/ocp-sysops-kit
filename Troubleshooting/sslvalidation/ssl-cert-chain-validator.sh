#!/usr/bin/env bash

set -uo pipefail

##############################################################################
# Certificate Chain Validator
#
# Purpose:
#   Validate a TLS certificate, private key, certificate chain and root CA.
#
# Features:
#   - Bundle or separate certificate mode
#   - Certificate inventory
#   - Leaf/intermediate/root classification
#   - Duplicate certificate detection
#   - SHA-256 fingerprint comparison
#   - Private key matching
#   - Certificate validity / expiry warning
#   - SAN inspection
#   - Optional hostname/IP validation
#   - EKU / Key Usage inspection
#   - Public key algorithm / size
#   - Signature algorithm
#   - Cryptographic chain validation
#   - Root CA validation
#   - Human-readable or JSON summary
#
# Exit codes:
#   0 = PASS
#   1 = FAIL
#   2 = PASS WITH WARNINGS
#   3 = USAGE ERROR
#   4 = INPUT / PARSING ERROR
##############################################################################

VERSION="2.0"

##############################################################################
# Configuration
##############################################################################

DEFAULT_WARN_DAYS=30

WARN_DAYS="$DEFAULT_WARN_DAYS"

CERT=""
BUNDLE=""
KEY=""
ROOT=""
HOSTNAME=""
IP=""
JSON_OUTPUT=false

declare -a INTERMEDIATES=()
declare -a CERT_FILES=()
declare -a CA_CERTS=()
declare -a LEAF_CERTS=()

PASS=0
WARN=0
FAIL=0

WORKDIR=""

##############################################################################
# Exit codes
##############################################################################

EXIT_PASS=0
EXIT_FAIL=1
EXIT_WARN=2
EXIT_USAGE=3
EXIT_INPUT=4

##############################################################################
# Colors
#
# Disable automatically when stdout is not a terminal or --json is used.
##############################################################################

if [[ -t 1 && "${NO_COLOR:-}" != "1" ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    RESET=""
fi

##############################################################################
# Usage
##############################################################################

usage() {
cat <<EOF

Certificate Chain Validation Utility v${VERSION}

USAGE

Bundle Mode:
  $0 \\
    --bundle fullchain.pem \\
    --key server.key \\
    --root rootCA.crt

Separate File Mode:
  $0 \\
    --cert server.crt \\
    --intermediate intermediate1.crt \\
    --intermediate intermediate2.crt \\
    --key server.key \\
    --root rootCA.crt

OPTIONS

  --bundle FILE
        PEM containing server certificate + intermediate(s)

  --cert FILE
        Server/leaf certificate

  --intermediate FILE
        Intermediate CA certificate.
        Can be specified multiple times.

  --key FILE
        Private key corresponding to the server certificate

  --root FILE
        Trusted root CA certificate

  --hostname NAME
        Validate the server certificate against a DNS hostname

  --ip ADDRESS
        Validate the server certificate against an IP address

  --warn-days DAYS
        Warn when a certificate expires within DAYS.
        Default: ${DEFAULT_WARN_DAYS}

  --json
        Output machine-readable JSON summary

  -h, --help
        Display this help

EXAMPLES

  $0 \\
    --bundle tls.crt \\
    --key tls.key \\
    --root rootCA.crt

  $0 \\
    --cert server.crt \\
    --intermediate inter1.crt \\
    --intermediate inter2.crt \\
    --key server.key \\
    --root rootCA.crt

  $0 \\
    --bundle tls.crt \\
    --key tls.key \\
    --root rootCA.crt \\
    --hostname api.example.com

  $0 \\
    --bundle tls.crt \\
    --key tls.key \\
    --root rootCA.crt \\
    --warn-days 60

  $0 \\
    --bundle tls.crt \\
    --key tls.key \\
    --root rootCA.crt \\
    --json

EXIT CODES

  0  PASS
  1  FAIL
  2  PASS WITH WARNINGS
  3  Usage error
  4  Input/parsing error

EOF
}

##############################################################################
# Logging
##############################################################################

log_info() {
    $JSON_OUTPUT && return 0
    printf '%s[INFO]%s %s\n' "$BLUE" "$RESET" "$*"
}

log_pass() {
    $JSON_OUTPUT && return 0
    printf '%s[PASS]%s %s\n' "$GREEN" "$RESET" "$*"
}

log_warn() {
    $JSON_OUTPUT && return 0
    printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"
}

log_fail() {
    $JSON_OUTPUT && return 0
    printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*"
}

section() {
    $JSON_OUTPUT && return 0

    echo
    printf '%s%s================================================================%s\n' \
        "$BOLD" "$BLUE" "$RESET"
    printf '%s%s%s\n' "$BOLD" "$*" "$RESET"
    printf '%s%s================================================================%s\n' \
        "$BOLD" "$BLUE" "$RESET"
}

##############################################################################
# Counters
##############################################################################

pass_check() {
    ((PASS++))
}

warn_check() {
    ((WARN++))
}

fail_check() {
    ((FAIL++))
}

##############################################################################
# Cleanup
##############################################################################

cleanup() {
    if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
        rm -rf -- "$WORKDIR"
    fi
}

trap cleanup EXIT INT TERM

##############################################################################
# Argument helpers
##############################################################################

require_value() {
    local option="$1"

    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "ERROR: $option requires a value" >&2
        usage
        exit "$EXIT_USAGE"
    fi
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

##############################################################################
# Argument parsing
##############################################################################

while [[ $# -gt 0 ]]; do

    case "$1" in

        --bundle)
            require_value "$@"
            BUNDLE="$2"
            shift 2
            ;;

        --cert)
            require_value "$@"
            CERT="$2"
            shift 2
            ;;

        --intermediate)
            require_value "$@"
            INTERMEDIATES+=("$2")
            shift 2
            ;;

        --key)
            require_value "$@"
            KEY="$2"
            shift 2
            ;;

        --root)
            require_value "$@"
            ROOT="$2"
            shift 2
            ;;

        --hostname)
            require_value "$@"
            HOSTNAME="$2"
            shift 2
            ;;

        --ip)
            require_value "$@"
            IP="$2"
            shift 2
            ;;

        --warn-days)
            require_value "$@"

            if ! is_positive_integer "$2"; then
                echo "ERROR: --warn-days must be a positive integer" >&2
                exit "$EXIT_USAGE"
            fi

            WARN_DAYS="$2"
            shift 2
            ;;

        --json)
            JSON_OUTPUT=true
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            exit "$EXIT_USAGE"
            ;;

    esac

done

##############################################################################
# Argument validation
##############################################################################

if [[ -z "$KEY" ]]; then
    echo "ERROR: --key is mandatory" >&2
    usage
    exit "$EXIT_USAGE"
fi

if [[ -z "$ROOT" ]]; then
    echo "ERROR: --root is mandatory" >&2
    usage
    exit "$EXIT_USAGE"
fi

if [[ -z "$BUNDLE" && -z "$CERT" ]]; then
    echo "ERROR: specify either --bundle or --cert" >&2
    usage
    exit "$EXIT_USAGE"
fi

if [[ -n "$BUNDLE" && -n "$CERT" ]]; then
    echo "ERROR: use either --bundle or --cert, not both" >&2
    exit "$EXIT_USAGE"
fi

if [[ -n "$HOSTNAME" && -n "$IP" ]]; then
    echo "ERROR: use either --hostname or --ip, not both" >&2
    exit "$EXIT_USAGE"
fi

##############################################################################
# File validation
##############################################################################

check_file() {
    local file="$1"
    local description="$2"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: $description not found: $file" >&2
        exit "$EXIT_INPUT"
    fi

    if [[ ! -r "$file" ]]; then
        echo "ERROR: $description is not readable: $file" >&2
        exit "$EXIT_INPUT"
    fi
}

check_file "$KEY" "Private key"
check_file "$ROOT" "Root CA"

if [[ -n "$BUNDLE" ]]; then
    check_file "$BUNDLE" "Bundle"
fi

if [[ -n "$CERT" ]]; then
    check_file "$CERT" "Server certificate"
fi

for intermediate in "${INTERMEDIATES[@]}"; do
    check_file "$intermediate" "Intermediate certificate"
done

##############################################################################
# OpenSSL validation
##############################################################################

if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl command not found" >&2
    exit "$EXIT_INPUT"
fi

OPENSSL_VERSION="$(openssl version 2>/dev/null || true)"

if [[ -z "$OPENSSL_VERSION" ]]; then
    echo "ERROR: unable to determine OpenSSL version" >&2
    exit "$EXIT_INPUT"
fi

##############################################################################
# Secure temporary directory
##############################################################################

umask 077

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/cert-validator.XXXXXX")" || {
    echo "ERROR: unable to create secure temporary directory" >&2
    exit "$EXIT_INPUT"
}

EXTRACT_DIR="$WORKDIR/extracted"
CHAIN_FILE="$WORKDIR/chain.pem"

mkdir -p "$EXTRACT_DIR" || {
    echo "ERROR: unable to create temporary workspace" >&2
    exit "$EXIT_INPUT"
}

##############################################################################
# Certificate helper functions
##############################################################################

cert_subject() {
    openssl x509 -in "$1" -noout -subject 2>/dev/null
}

cert_issuer() {
    openssl x509 -in "$1" -noout -issuer 2>/dev/null
}

cert_serial() {
    openssl x509 -in "$1" -noout -serial 2>/dev/null
}

cert_fingerprint() {
    openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null |
        sed 's/^.*=//'
}

cert_not_before() {
    openssl x509 -in "$1" -noout -startdate 2>/dev/null |
        sed 's/^notBefore=//'
}

cert_not_after() {
    openssl x509 -in "$1" -noout -enddate 2>/dev/null |
        sed 's/^notAfter=//'
}

##############################################################################
# Validate a PEM contains exactly one certificate
##############################################################################

validate_single_certificate() {
    local file="$1"

    local count
    count="$(grep -c -- "-----BEGIN CERTIFICATE-----" "$file" 2>/dev/null || true)"

    if [[ "$count" -ne 1 ]]; then
        return 1
    fi

    openssl x509 -in "$file" -noout >/dev/null 2>&1
}

##############################################################################
# Extract certificates from bundle
##############################################################################

extract_bundle() {

    log_info "Using bundle mode"

    local count=0
    local in_cert=0
    local outfile=""

    while IFS= read -r line || [[ -n "$line" ]]; do

        if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then

            ((count++))

            outfile="$EXTRACT_DIR/cert-${count}.pem"
            in_cert=1

        fi

        if (( in_cert )); then
            printf '%s\n' "$line" >> "$outfile"
        fi

        if [[ "$line" == "-----END CERTIFICATE-----" ]]; then
            in_cert=0
        fi

    done < "$BUNDLE"

    if [[ "$count" -eq 0 ]]; then
        log_fail "No PEM certificates found in bundle"
        return 1
    fi

    log_info "Certificates extracted from bundle: $count"

    local file

    for file in "$EXTRACT_DIR"/*.pem; do
        if ! validate_single_certificate "$file"; then
            log_fail "Invalid certificate PEM: $(basename "$file")"
            return 1
        fi
    done

    return 0
}

##############################################################################
# Prepare separate certificate mode
##############################################################################

prepare_separate_mode() {

    log_info "Using separate certificate mode"

    local output
    local count=1

    output="$EXTRACT_DIR/server.pem"

    if ! validate_single_certificate "$CERT"; then
        log_fail "Invalid server certificate: $CERT"
        return 1
    fi

    cp -- "$CERT" "$output"

    local intermediate

    for intermediate in "${INTERMEDIATES[@]}"; do

        if ! validate_single_certificate "$intermediate"; then
            log_fail "Invalid intermediate certificate: $intermediate"
            return 1
        fi

        output="$EXTRACT_DIR/intermediate-${count}.pem"

        cp -- "$intermediate" "$output"

        ((count++))
    done

    return 0
}

##############################################################################
# Certificate classification
#
# Returns:
#   CA    -> Basic Constraints CA:TRUE
#   LEAF  -> CA:FALSE or no CA:TRUE
##############################################################################

is_ca_certificate() {

    local file="$1"
    local bc

    bc="$(openssl x509 \
        -in "$file" \
        -noout \
        -ext basicConstraints 2>/dev/null || true)"

    if printf '%s\n' "$bc" | grep -qE 'CA:TRUE'; then
        return 0
    fi

    return 1
}

##############################################################################
# Inventory
##############################################################################

build_inventory() {

    section "CERTIFICATE INVENTORY"

    local file
    local subject
    local issuer
    local fingerprint
    local serial
    local not_before
    local not_after
    local pubkey
    local sigalg

    for file in "$EXTRACT_DIR"/*.pem; do

        if [[ ! -f "$file" ]]; then
            continue
        fi

        if ! validate_single_certificate "$file"; then
            log_fail "Invalid certificate: $(basename "$file")"
            fail_check
            continue
        fi

        subject="$(cert_subject "$file")"
        issuer="$(cert_issuer "$file")"
        fingerprint="$(cert_fingerprint "$file")"
        serial="$(cert_serial "$file")"
        not_before="$(cert_not_before "$file")"
        not_after="$(cert_not_after "$file")"

        pubkey="$(
            openssl x509 \
                -in "$file" \
                -noout \
                -text 2>/dev/null |
            grep -m1 -E 'Public-Key:|Public key:|id-ecPublicKey|ED25519|ED448' |
            sed 's/^[[:space:]]*//'
        )"

        sigalg="$(
            openssl x509 \
                -in "$file" \
                -noout \
                -text 2>/dev/null |
            grep -m1 'Signature Algorithm:' |
            sed 's/^[[:space:]]*//'
        )"

        CERT_FILES+=("$file")

        if is_ca_certificate "$file"; then

            CA_CERTS+=("$file")
            cert_type="CA"

        else

            LEAF_CERTS+=("$file")
            cert_type="LEAF"

        fi

        if $JSON_OUTPUT; then
            continue
        fi

        echo
        printf '%s\n' "File          : $(basename "$file")"
        printf '%s\n' "Type          : $cert_type"
        printf '%s\n' "$subject"
        printf '%s\n' "$issuer"
        printf '%s\n' "$serial"
        printf '%s\n' "SHA256        : $fingerprint"
        printf '%s\n' "Not Before    : $not_before"
        printf '%s\n' "Not After     : $not_after"

        if [[ -n "$pubkey" ]]; then
            printf '%s\n' "Public Key    : $pubkey"
        fi

        if [[ -n "$sigalg" ]]; then
            printf '%s\n' "Signature     : $sigalg"
        fi

    done

    if [[ "${#CERT_FILES[@]}" -eq 0 ]]; then
        log_fail "No valid certificates found"
        return 1
    fi

    return 0
}

##############################################################################
# Duplicate detection
##############################################################################

check_duplicate_certificates() {

    section "DUPLICATE CERTIFICATE CHECK"

    declare -A fingerprints=()
    local file
    local fp
    local duplicate_found=false

    for file in "${CERT_FILES[@]}"; do

        fp="$(cert_fingerprint "$file")"

        if [[ -z "$fp" ]]; then
            continue
        fi

        if [[ -n "${fingerprints[$fp]:-}" ]]; then

            log_warn "Duplicate certificate detected:"
            echo "        $(basename "$file")"
            echo "        $(basename "${fingerprints[$fp]}")"
            echo "        SHA256: $fp"

            warn_check
            duplicate_found=true

        else

            fingerprints["$fp"]="$file"

        fi

    done

    if ! $duplicate_found; then
        log_pass "No duplicate certificates detected"
        pass_check
    fi
}

##############################################################################
# Leaf validation
##############################################################################

validate_leaf() {

    section "LEAF CERTIFICATE VALIDATION"

    local count="${#LEAF_CERTS[@]}"

    if [[ "$count" -eq 0 ]]; then
        log_fail "No leaf/server certificate detected"
        fail_check
        return 1
    fi

    if [[ "$count" -gt 1 ]]; then

        log_fail "Multiple leaf/server certificates detected"

        local leaf
        for leaf in "${LEAF_CERTS[@]}"; do
            echo "        $(basename "$leaf")"
        done

        echo
        echo "        A validation bundle must contain exactly one"
        echo "        server/leaf certificate."

        fail_check
        return 1
    fi

    SERVER="${LEAF_CERTS[0]}"

    log_pass "Exactly one leaf/server certificate detected"
    pass_check

    return 0
}

##############################################################################
# Root validation
##############################################################################

validate_root() {

    section "ROOT CA VALIDATION"

    local root_fp
    local root_subject
    local root_issuer

    if ! validate_single_certificate "$ROOT"; then
        log_fail "Root CA is not a valid single PEM certificate"
        fail_check
        return 1
    fi

    root_fp="$(cert_fingerprint "$ROOT")"
    root_subject="$(cert_subject "$ROOT")"
    root_issuer="$(cert_issuer "$ROOT")"

    echo
    echo "Root CA:"
    echo "  $root_subject"
    echo "  $root_issuer"
    echo "  SHA256 : $root_fp"

    if ! is_ca_certificate "$ROOT"; then
        log_fail "Root certificate does not contain CA:TRUE"
        fail_check
    else
        log_pass "Root certificate has CA:TRUE"
        pass_check
    fi

    if [[ "$root_subject" == "$root_issuer" ]]; then
        log_pass "Root certificate is self-issued by subject/issuer"
        pass_check
    else
        log_warn "Root subject and issuer differ; root may not be self-signed"
        warn_check
    fi

    if openssl verify -CAfile "$ROOT" "$ROOT" >/dev/null 2>&1; then
        log_pass "Root certificate self-verification successful"
        pass_check
    else
        log_warn "Root certificate could not self-verify"
        warn_check
    fi
}

##############################################################################
# Root inside bundle
##############################################################################

check_root_in_bundle() {

    section "BUNDLE ROOT CHECK"

    local root_fp
    root_fp="$(cert_fingerprint "$ROOT")"

    local file
    local fp
    local found=false

    for file in "${CERT_FILES[@]}"; do

        fp="$(cert_fingerprint "$file")"

        if [[ "$fp" == "$root_fp" ]]; then

            log_warn "Root CA is included in supplied bundle:"
            echo "        $(basename "$file")"
            echo "        SHA256: $fp"

            warn_check
            found=true

        fi

    done

    if ! $found; then
        log_pass "Trusted root is not included in supplied bundle"
        pass_check
    fi
}

##############################################################################
# Server details
##############################################################################

show_server_details() {

    section "SERVER CERTIFICATE DETAILS"

    local subject
    local issuer
    local serial
    local not_before
    local not_after
    local fingerprint

    subject="$(cert_subject "$SERVER")"
    issuer="$(cert_issuer "$SERVER")"
    serial="$(cert_serial "$SERVER")"
    not_before="$(cert_not_before "$SERVER")"
    not_after="$(cert_not_after "$SERVER")"
    fingerprint="$(cert_fingerprint "$SERVER")"

    echo
    echo "Subject       : $subject"
    echo "Issuer        : $issuer"
    echo "Serial        : $serial"
    echo "SHA256        : $fingerprint"
    echo "Not Before    : $not_before"
    echo "Not After     : $not_after"

    echo
    echo "SAN Entries:"

    local san

    san="$(
        openssl x509 \
            -in "$SERVER" \
            -noout \
            -ext subjectAltName 2>/dev/null |
        sed -n '/Subject Alternative Name/,$p' |
        sed '1d' |
        sed 's/^[[:space:]]*//'
    )"

    if [[ -n "$san" ]]; then
        echo "$san"
    else
        echo "  NONE"
    fi
}

##############################################################################
# Key validation
##############################################################################

validate_key() {

    section "PRIVATE KEY VALIDATION"

    local cert_hash
    local key_hash

    if ! openssl pkey -in "$KEY" -noout >/dev/null 2>&1; then
        log_fail "Unable to parse private key"
        fail_check
        return 1
    fi

    cert_hash="$(
        openssl x509 \
            -in "$SERVER" \
            -pubkey \
            -noout 2>/dev/null |
        openssl pkey \
            -pubin \
            -outform DER 2>/dev/null |
        openssl dgst -sha256 |
        awk '{print $2}'
    )"

    key_hash="$(
        openssl pkey \
            -in "$KEY" \
            -pubout 2>/dev/null |
        openssl pkey \
            -pubin \
            -outform DER 2>/dev/null |
        openssl dgst -sha256 |
        awk '{print $2}'
    )"

    if [[ -z "$cert_hash" || -z "$key_hash" ]]; then
        log_fail "Unable to calculate certificate/key public-key fingerprints"
        fail_check
        return 1
    fi

    echo "Certificate public key SHA256 : $cert_hash"
    echo "Private key public key SHA256 : $key_hash"

    if [[ "$cert_hash" == "$key_hash" ]]; then
        log_pass "Private key matches server certificate"
        pass_check
    else
        log_fail "Private key does NOT match server certificate"
        fail_check
    fi
}

##############################################################################
# Certificate validity
##############################################################################

validate_expiry() {

    section "CERTIFICATE VALIDITY"

    local file
    local not_before
    local not_after
    local warn_seconds
    local status

    warn_seconds=$((WARN_DAYS * 86400))

    for file in "${CERT_FILES[@]}"; do

        not_before="$(cert_not_before "$file")"
        not_after="$(cert_not_after "$file")"

        echo
        echo "$(basename "$file")"
        echo "  Not Before : $not_before"
        echo "  Not After  : $not_after"

        # Not yet valid
        if ! openssl x509 -in "$file" -checkend 0 -noout >/dev/null 2>&1; then

            # Determine whether this is expired or not-yet-valid.
            if openssl x509 -in "$file" -checkend 0 -noout >/dev/null 2>&1; then
                :
            fi

        fi

        # Current validity
        if openssl x509 -in "$file" -checkend 0 -noout >/dev/null 2>&1; then

            # Check expiry warning window.
            if openssl x509 \
                -in "$file" \
                -checkend "$warn_seconds" \
                -noout >/dev/null 2>&1
            then

                log_pass "Certificate is currently valid"
                pass_check

            else

                log_warn "Certificate expires within ${WARN_DAYS} days"
                warn_check

            fi

        else

            # checkend 0 only tells us it is not valid for expiry.
            # Determine whether start date is in the future.
            local start_epoch
            local now_epoch

            start_epoch="$(date -d "$not_before" +%s 2>/dev/null || echo 0)"
            now_epoch="$(date +%s)"

            if [[ "$start_epoch" -gt "$now_epoch" ]]; then
                log_fail "Certificate is not yet valid"
            else
                log_fail "Certificate has expired"
            fi

            fail_check
        fi

    done
}

##############################################################################
# Certificate policy information
##############################################################################

validate_certificate_policy() {

    section "CERTIFICATE POLICY"

    local eku
    local ku
    local pubkey_info
    local sigalg

    echo
    echo "Extended Key Usage:"

    eku="$(
        openssl x509 \
            -in "$SERVER" \
            -noout \
            -ext extendedKeyUsage 2>/dev/null |
        sed -n '/Extended Key Usage/,$p' |
        sed '1d' |
        sed 's/^[[:space:]]*//'
    )"

    if [[ -n "$eku" ]]; then
        echo "$eku"

        if printf '%s\n' "$eku" |
            grep -qiE 'TLS Web Server Authentication|serverAuth'
        then
            log_pass "serverAuth EKU is present"
            pass_check
        else
            log_warn "serverAuth EKU not detected"
            warn_check
        fi

    else
        echo "  Not explicitly present"
        log_warn "Extended Key Usage extension is not present"
        warn_check
    fi

    echo
    echo "Key Usage:"

    ku="$(
        openssl x509 \
            -in "$SERVER" \
            -noout \
            -ext keyUsage 2>/dev/null |
        sed -n '/Key Usage/,$p' |
        sed '1d' |
        sed 's/^[[:space:]]*//'
    )"

    if [[ -n "$ku" ]]; then
        echo "$ku"
        log_pass "Key Usage extension detected"
        pass_check
    else
        echo "  Not explicitly present"
        log_warn "Key Usage extension is not present"
        warn_check
    fi

    echo
    echo "Public Key:"

    pubkey_info="$(
        openssl x509 \
            -in "$SERVER" \
            -noout \
            -text 2>/dev/null |
        grep -m1 -E 'Public-Key:|Public key:'
    )"

    if [[ -n "$pubkey_info" ]]; then
        echo "  $pubkey_info"
    else
        openssl x509 \
            -in "$SERVER" \
            -noout \
            -text 2>/dev/null |
        grep -m1 -E 'id-ecPublicKey|ED25519|ED448|rsaEncryption' |
        sed 's/^[[:space:]]*/  /'
    fi

    echo
    echo "Signature Algorithm:"

    sigalg="$(
        openssl x509 \
            -in "$SERVER" \
            -noout \
            -text 2>/dev/null |
        grep -m1 'Signature Algorithm:' |
        sed 's/^[[:space:]]*//'
    )"

    echo "  ${sigalg:-Unknown}"

    # Report weak SHA-1 signatures as warning.
    if printf '%s\n' "$sigalg" | grep -qi 'sha1'; then
        log_warn "Server certificate uses SHA-1 signature algorithm"
        warn_check
    else
        log_pass "Server certificate does not use SHA-1 signature"
        pass_check
    fi
}

##############################################################################
# Chain relationships
##############################################################################

show_chain_relationships() {

    section "CHAIN RELATIONSHIPS"

    local file
    local subject
    local issuer

    for file in "${CERT_FILES[@]}"; do

        subject="$(cert_subject "$file")"
        issuer="$(cert_issuer "$file")"

        echo
        echo "$(basename "$file")"
        echo "  Subject : $subject"
        echo "  Issuer  : $issuer"

    done

    echo
    echo "Trusted Root:"
    echo "  $(cert_subject "$ROOT")"
}

##############################################################################
# Build untrusted chain
##############################################################################

build_untrusted_chain() {

    : > "$CHAIN_FILE"

    local file
    local root_fp
    local fp

    root_fp="$(cert_fingerprint "$ROOT")"

    for file in "${CA_CERTS[@]}"; do

        fp="$(cert_fingerprint "$file")"

        # Never include the trusted root in -untrusted.
        if [[ "$fp" == "$root_fp" ]]; then
            continue
        fi

        cat "$file" >> "$CHAIN_FILE"

    done
}

##############################################################################
# Cryptographic chain validation
##############################################################################

validate_chain() {

    section "CHAIN VALIDATION"

    build_untrusted_chain

    local verify_output
    local rc

    verify_output="$(
        openssl verify \
            -verbose \
            -show_chain \
            -CAfile "$ROOT" \
            -untrusted "$CHAIN_FILE" \
            "$SERVER" 2>&1
    )"

    rc=$?

    echo "$verify_output"

    if [[ "$rc" -eq 0 ]]; then
        log_pass "Full certificate chain validation successful"
        pass_check
    else
        log_fail "Certificate chain validation failed"
        fail_check
    fi
}

##############################################################################
# Hostname / IP validation
##############################################################################

validate_identity() {

    if [[ -z "$HOSTNAME" && -z "$IP" ]]; then
        return 0
    fi

    section "IDENTITY VALIDATION"

    local output
    local rc

    if [[ -n "$HOSTNAME" ]]; then

        echo "Hostname : $HOSTNAME"

        if ! openssl verify -help 2>&1 |
            grep -q -- '-verify_hostname'
        then
            log_fail "Installed OpenSSL does not support -verify_hostname"
            fail_check
            return
        fi

        output="$(
            openssl verify \
                -CAfile "$ROOT" \
                -untrusted "$CHAIN_FILE" \
                -verify_hostname "$HOSTNAME" \
                "$SERVER" 2>&1
        )"

        rc=$?

    else

        echo "IP Address : $IP"

        if ! openssl verify -help 2>&1 |
            grep -q -- '-verify_ip'
        then
            log_fail "Installed OpenSSL does not support -verify_ip"
            fail_check
            return
        fi

        output="$(
            openssl verify \
                -CAfile "$ROOT" \
                -untrusted "$CHAIN_FILE" \
                -verify_ip "$IP" \
                "$SERVER" 2>&1
        )"

        rc=$?

    fi

    echo "$output"

    if [[ "$rc" -eq 0 ]]; then
        log_pass "Certificate identity validation successful"
        pass_check
    else
        log_fail "Certificate identity validation failed"
        fail_check
    fi
}

##############################################################################
# SAN validation information
##############################################################################

validate_san_presence() {

    section "SAN VALIDATION"

    local san

    san="$(
        openssl x509 \
            -in "$SERVER" \
            -noout \
            -ext subjectAltName 2>/dev/null |
        sed -n '/Subject Alternative Name/,$p' |
        sed '1d'
    )"

    if [[ -n "$san" ]]; then
        log_pass "Subject Alternative Name extension is present"
        pass_check
    else
        log_warn "Subject Alternative Name extension is missing"
        warn_check
    fi
}

##############################################################################
# Final summary
##############################################################################

print_summary() {

    section "SUMMARY"

    local result

    if [[ "$FAIL" -gt 0 ]]; then
        result="FAIL"
    elif [[ "$WARN" -gt 0 ]]; then
        result="PASS WITH WARNINGS"
    else
        result="PASS"
    fi

    echo
    echo "Checks Passed : $PASS"
    echo "Warnings      : $WARN"
    echo "Failures      : $FAIL"
    echo
    echo "OVERALL RESULT : $result"

    echo
    echo "OpenSSL        : $OPENSSL_VERSION"
    echo "Warning Window : ${WARN_DAYS} days"

    if [[ -n "$HOSTNAME" ]]; then
        echo "Hostname       : $HOSTNAME"
    fi

    if [[ -n "$IP" ]]; then
        echo "IP Address     : $IP"
    fi

    FINAL_RESULT="$result"
}

##############################################################################
# JSON helpers
##############################################################################

json_escape() {

    local value="$1"

    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"

    printf '%s' "$value"
}

##############################################################################
# JSON summary
##############################################################################

print_json_summary() {

    local result

    if [[ "$FAIL" -gt 0 ]]; then
        result="FAIL"
    elif [[ "$WARN" -gt 0 ]]; then
        result="PASS_WITH_WARNINGS"
    else
        result="PASS"
    fi

    local server_subject=""
    local server_issuer=""
    local server_fp=""
    local server_not_after=""

    if [[ -n "${SERVER:-}" && -f "${SERVER:-}" ]]; then
        server_subject="$(cert_subject "$SERVER")"
        server_issuer="$(cert_issuer "$SERVER")"
        server_fp="$(cert_fingerprint "$SERVER")"
        server_not_after="$(cert_not_after "$SERVER")"
    fi

    printf '{\n'
    printf '  "version": "%s",\n' "$VERSION"
    printf '  "result": "%s",\n' "$result"
    printf '  "checks_passed": %d,\n' "$PASS"
    printf '  "warnings": %d,\n' "$WARN"
    printf '  "failures": %d,\n' "$FAIL"
    printf '  "warn_days": %d,\n' "$WARN_DAYS"
    printf '  "openssl": "%s",\n' "$(json_escape "$OPENSSL_VERSION")"
    printf '  "server": {\n'
    printf '    "subject": "%s",\n' "$(json_escape "$server_subject")"
    printf '    "issuer": "%s",\n' "$(json_escape "$server_issuer")"
    printf '    "sha256": "%s",\n' "$(json_escape "$server_fp")"
    printf '    "not_after": "%s"\n' "$(json_escape "$server_not_after")"
    printf '  },\n'
    printf '  "certificate_count": %d,\n' "${#CERT_FILES[@]}"
    printf '  "ca_count": %d,\n' "${#CA_CERTS[@]}"
    printf '  "leaf_count": %d\n' "${#LEAF_CERTS[@]}"
    printf '}\n'
}

##############################################################################
# Main
##############################################################################

main() {

    if ! $JSON_OUTPUT; then

        echo
        printf '%s%sCertificate Chain Validation Utility v%s%s\n' \
            "$BOLD" "$BLUE" "$VERSION" "$RESET"

        echo
        echo "OpenSSL: $OPENSSL_VERSION"

    fi

    ##########################################################################
    # Extract input
    ##########################################################################

    if [[ -n "$BUNDLE" ]]; then

        if ! extract_bundle; then
            exit "$EXIT_INPUT"
        fi

    else

        if ! prepare_separate_mode; then
            exit "$EXIT_INPUT"
        fi

    fi

    ##########################################################################
    # Inventory
    ##########################################################################

    if ! build_inventory; then
        exit "$EXIT_INPUT"
    fi

    ##########################################################################
    # Structural checks
    ##########################################################################

    check_duplicate_certificates

    if ! validate_leaf; then
        exit "$EXIT_FAIL"
    fi

    validate_root

    check_root_in_bundle

    ##########################################################################
    # Certificate information
    ##########################################################################

    show_server_details

    ##########################################################################
    # Key
    ##########################################################################

    validate_key

    ##########################################################################
    # Validity
    ##########################################################################

    validate_expiry

    ##########################################################################
    # Certificate policy
    ##########################################################################

    validate_certificate_policy

    ##########################################################################
    # SAN
    ##########################################################################

    validate_san_presence

    ##########################################################################
    # Chain
    ##########################################################################

    show_chain_relationships

    validate_chain

    ##########################################################################
    # Optional identity validation
    ##########################################################################

    validate_identity

    ##########################################################################
    # Summary
    ##########################################################################

    if $JSON_OUTPUT; then
        print_json_summary
    else
        print_summary
    fi

    ##########################################################################
    # Exit status
    ##########################################################################

    if [[ "$FAIL" -gt 0 ]]; then
        exit "$EXIT_FAIL"
    fi

    if [[ "$WARN" -gt 0 ]]; then
        exit "$EXIT_WARN"
    fi

    exit "$EXIT_PASS"
}

##############################################################################
# Run
##############################################################################

main "$@"
