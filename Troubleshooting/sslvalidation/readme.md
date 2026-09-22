# Certificate Chain Validator

A production-oriented Bash utility for validating TLS/SSL certificates, private keys, certificate chains, trusted root CAs, certificate expiry, SANs, EKU, and optional hostname/IP identity.

The utility supports both **full certificate bundle** and **separate certificate/intermediate** input modes.

---

## Features

* Validate TLS server/leaf certificates
* Validate private key matches the server certificate
* Validate complete certificate chains
* Support multiple intermediate certificates
* Validate trusted root CA
* Detect duplicate certificates
* Detect root CA included in the supplied bundle
* Display SHA-256 certificate fingerprints
* Check certificate `Not Before` and `Not After`
* Warn when certificates are close to expiry
* Display Subject, Issuer, Serial Number and SAN
* Display Key Usage and Extended Key Usage
* Display public-key information
* Display certificate signature algorithm
* Detect SHA-1 signed certificates
* Optional hostname validation
* Optional IP address validation
* Human-readable output
* JSON output for automation/CI pipelines
* Meaningful exit codes
* Secure temporary workspace
* Does not copy the private key into the temporary workspace

---

## Requirements

The script requires:

* Bash
* OpenSSL

Recommended:

```text
Bash 4+
OpenSSL 1.1.1+
```

The script is primarily intended for Linux/RHEL environments.

Check your versions:

```bash
bash --version
openssl version
```

Example:

```text
OpenSSL 3.0.x
```

---

# Installation

Clone the repository:

```bash
git clone <repository-url>
cd <repository-directory>
```

Make the script executable:

```bash
chmod +x cert-validator.sh
```

Run:

```bash
./cert-validator.sh --help
```

---

# Basic Usage

The utility supports two certificate input modes.

## Bundle Mode

Use this when you have a PEM file containing:

```text
Server Certificate
        |
        v
Intermediate CA
        |
        v
Intermediate CA
```

Example:

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt
```

Example bundle:

```text
-----BEGIN CERTIFICATE-----
Server certificate
-----END CERTIFICATE-----

-----BEGIN CERTIFICATE-----
Intermediate CA
-----END CERTIFICATE-----

-----BEGIN CERTIFICATE-----
Intermediate CA
-----END CERTIFICATE-----
```

The trusted root should normally be supplied separately using:

```text
--root
```

rather than included in the server certificate bundle.

---

# Separate Certificate Mode

Use this when the server certificate and intermediate certificates are separate files.

```bash
./cert-validator.sh \
  --cert server.crt \
  --intermediate intermediate1.crt \
  --intermediate intermediate2.crt \
  --key server.key \
  --root rootCA.crt
```

Multiple `--intermediate` arguments are supported.

Example:

```bash
./cert-validator.sh \
  --cert server.crt \
  --intermediate intermediate-ca-1.crt \
  --intermediate intermediate-ca-2.crt \
  --key server.key \
  --root root-ca.crt
```

---

# Command-Line Options

| Option                |    Required | Description                                                         |
| --------------------- | ----------: | ------------------------------------------------------------------- |
| `--bundle FILE`       | Conditional | PEM containing server certificate and intermediate certificates     |
| `--cert FILE`         | Conditional | Server/leaf certificate                                             |
| `--intermediate FILE` |          No | Intermediate CA certificate; can be specified multiple times        |
| `--key FILE`          |         Yes | Private key corresponding to the server certificate                 |
| `--root FILE`         |         Yes | Trusted root CA certificate                                         |
| `--hostname NAME`     |          No | Validate certificate against a DNS hostname                         |
| `--ip ADDRESS`        |          No | Validate certificate against an IP address                          |
| `--warn-days DAYS`    |          No | Warn when a certificate expires within the specified number of days |
| `--json`              |          No | Produce machine-readable JSON output                                |
| `-h`, `--help`        |          No | Display help                                                        |

---

# Important Input Rules

The following are required:

```text
--key
--root
```

Either:

```text
--bundle
```

or:

```text
--cert
```

must be supplied.

They cannot be used together.

### Valid

```bash
--bundle fullchain.pem --key server.key --root rootCA.crt
```

### Valid

```bash
--cert server.crt \
--intermediate intermediate.crt \
--key server.key \
--root rootCA.crt
```

### Invalid

```bash
--bundle fullchain.pem \
--cert server.crt \
--key server.key \
--root rootCA.crt
```

---

# Certificate Validation Process

The utility performs validation in several stages.

```text
Input
 |
 +-- Argument validation
 |
 +-- File validation
 |
 +-- Certificate extraction
 |
 +-- Certificate inventory
 |
 +-- Certificate classification
 |      |
 |      +-- Leaf
 |      +-- Intermediate CA
 |      +-- Root
 |
 +-- Duplicate detection
 |
 +-- Root validation
 |
 +-- Private key validation
 |
 +-- Certificate validity
 |
 +-- Certificate policy checks
 |
 +-- SAN validation
 |
 +-- Chain relationship inspection
 |
 +-- Cryptographic chain validation
 |
 +-- Optional hostname/IP validation
 |
 +-- Final result
```

---

# Certificate Classification

The utility uses the certificate's **Basic Constraints** extension to identify CA certificates.

For example:

```text
Basic Constraints:
    CA:TRUE
```

is classified as a CA certificate.

A certificate without `CA:TRUE` is treated as a leaf/server certificate.

The utility also enforces:

```text
Exactly one leaf/server certificate
```

A bundle containing multiple leaf certificates is treated as a validation failure rather than silently selecting one.

---

# Certificate Inventory

The inventory displays information such as:

```text
File          : cert-1.pem
Type          : LEAF
Subject       : CN=api.example.com
Issuer        : CN=Example Intermediate CA
Serial        : 123456789
SHA256        : AABBCCDDEEFF...
Not Before    : Sep 01 00:00:00 2026 GMT
Not After     : Sep 01 00:00:00 2027 GMT
Public Key    : RSA Public-Key: (2048 bit)
Signature     : Signature Algorithm: sha256WithRSAEncryption
```

This is useful when troubleshooting certificate-chain problems.

---

# Private Key Validation

The utility verifies that the private key corresponds to the server certificate.

It compares the SHA-256 digest of the public key derived from:

```text
Server certificate
```

against the public key derived from:

```text
Private key
```

Example:

```text
Certificate public key SHA256 : abcdef...
Private key public key SHA256 : abcdef...

[PASS] Private key matches server certificate
```

If they differ:

```text
[FAIL] Private key does NOT match server certificate
```

The private key itself is never printed.

---

# Certificate Expiry Validation

The utility checks:

* `Not Before`
* `Not After`
* Current validity
* Expiry warning threshold

Default warning period:

```text
30 days
```

Example:

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt \
  --warn-days 60
```

A certificate that expires within the configured warning period generates:

```text
[WARN] Certificate expires within 60 days
```

An expired certificate generates:

```text
[FAIL] Certificate has expired
```

A certificate whose `Not Before` date is in the future generates:

```text
[FAIL] Certificate is not yet valid
```

---

# SAN Validation

The utility displays the Subject Alternative Name extension.

Example:

```text
SAN Entries:
DNS:api.example.com
DNS:api.internal.example.com
IP Address:10.10.10.20
```

It also checks whether the server certificate contains a SAN extension.

Example:

```text
[PASS] Subject Alternative Name extension is present
```

or:

```text
[WARN] Subject Alternative Name extension is missing
```

---

# Hostname Validation

Hostname validation can be explicitly requested.

Example:

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt \
  --hostname api.example.com
```

The validation uses OpenSSL certificate verification with hostname verification.

Example:

```text
IDENTITY VALIDATION

Hostname : api.example.com

api.example.com: OK

[PASS] Certificate identity validation successful
```

If the hostname does not match:

```text
[FAIL] Certificate identity validation failed
```

---

# IP Address Validation

An IP address can be validated using:

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt \
  --ip 10.10.10.20
```

The certificate must contain a matching IP SAN.

Example:

```text
IP Address : 10.10.10.20

[PASS] Certificate identity validation successful
```

---

# EKU Validation

The utility checks the Extended Key Usage extension.

For a typical TLS server certificate, the expected usage is:

```text
TLS Web Server Authentication
```

or:

```text
serverAuth
```

Example:

```text
Extended Key Usage:
    TLS Web Server Authentication

[PASS] serverAuth EKU is present
```

If it is not explicitly present:

```text
[WARN] Extended Key Usage extension is not present
```

The utility treats this as a warning rather than an automatic failure because certificate profiles can legitimately vary.

---

# Key Usage

The utility displays the certificate Key Usage extension.

For example:

```text
Key Usage:
    Digital Signature
    Key Encipherment
```

Example result:

```text
[PASS] Key Usage extension detected
```

---

# Signature Algorithm

The utility reports the certificate signature algorithm.

Example:

```text
Signature Algorithm:
    sha256WithRSAEncryption
```

SHA-1 signatures are reported as a warning:

```text
[WARN] Server certificate uses SHA-1 signature algorithm
```

---

# Root CA Validation

The trusted root supplied using:

```text
--root
```

is independently checked.

The utility validates:

* PEM format
* `CA:TRUE`
* Subject / Issuer relationship
* Root self-verification

Example:

```text
ROOT CA VALIDATION

Root CA:
  subject=CN=Example Root CA
  issuer=CN=Example Root CA
  SHA256 : AABBCCDDEEFF...

[PASS] Root certificate has CA:TRUE
[PASS] Root certificate is self-issued by subject/issuer
[PASS] Root certificate self-verification successful
```

---

# Root Certificate in Bundle

The root CA should normally not be included in the TLS server bundle.

For example, the preferred bundle is:

```text
Server
  |
  v
Intermediate
  |
  v
Intermediate
```

with the root supplied separately:

```text
--root rootCA.crt
```

If the root is detected inside the bundle:

```text
[WARN] Root CA is included in supplied bundle
```

The root is excluded from the `-untrusted` certificate set during chain validation.

---

# Duplicate Certificate Detection

The utility calculates SHA-256 fingerprints for certificates.

If the same certificate appears more than once:

```text
[WARN] Duplicate certificate detected:

        cert-3.pem
        cert-1.pem

        SHA256: AABBCCDDEEFF...
```

This is reported as a warning.

---

# Certificate Chain Validation

The actual cryptographic chain validation is performed using OpenSSL.

Conceptually:

```text
Server Certificate
       |
       v
Intermediate CA
       |
       v
Intermediate CA
       |
       v
Trusted Root CA
```

The utility uses:

```bash
openssl verify \
  -CAfile rootCA.crt \
  -untrusted chain.pem \
  server.pem
```

The trusted root is kept separate from the untrusted intermediate certificates.

Example successful result:

```text
CHAIN VALIDATION

server.pem: OK

Chain:
    server.pem
    intermediate-ca.pem
    rootCA.crt

[PASS] Full certificate chain validation successful
```

---

# Chain Relationship View

The utility also displays the Subject → Issuer relationships.

Example:

```text
CHAIN RELATIONSHIPS

server.pem
  Subject : CN=api.example.com
  Issuer  : CN=Example Intermediate CA

intermediate.pem
  Subject : CN=Example Intermediate CA
  Issuer  : CN=Example Root CA

Trusted Root:
  subject=CN=Example Root CA
```

This is useful for quickly identifying a missing or incorrect intermediate certificate.

---

# Output Status

The utility uses three operational result states.

## PASS

All checks passed.

```text
OVERALL RESULT : PASS
```

Exit code:

```text
0
```

---

## PASS WITH WARNINGS

No critical validation failure occurred, but one or more warnings were detected.

Example:

```text
OVERALL RESULT : PASS WITH WARNINGS
```

Exit code:

```text
2
```

Typical warnings include:

* Certificate expires soon
* Root included in bundle
* Duplicate certificate
* Missing EKU
* Missing Key Usage
* SHA-1 signature

---

## FAIL

One or more critical validation checks failed.

Example:

```text
OVERALL RESULT : FAIL
```

Exit code:

```text
1
```

Typical failures include:

* Invalid certificate
* Multiple leaf certificates
* No leaf certificate
* Expired certificate
* Certificate not yet valid
* Private key mismatch
* Invalid certificate chain
* Hostname mismatch
* IP SAN mismatch
* Invalid root CA

---

# Exit Codes

| Exit Code | Meaning                         |
| --------: | ------------------------------- |
|       `0` | Validation passed               |
|       `1` | Validation failed               |
|       `2` | Validation passed with warnings |
|       `3` | Command-line usage error        |
|       `4` | Input/parsing/environment error |

This allows the utility to be used in CI/CD pipelines.

Example:

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt

RC=$?

case "$RC" in
    0)
        echo "Certificate validation passed"
        ;;
    1)
        echo "Certificate validation failed"
        exit 1
        ;;
    2)
        echo "Certificate validation passed with warnings"
        ;;
    *)
        echo "Certificate validator execution error"
        exit 1
        ;;
esac
```

---

# JSON Output

The `--json` option produces machine-readable output.

Example:

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt \
  --json
```

Example output:

```json
{
  "version": "2.0",
  "result": "PASS_WITH_WARNINGS",
  "checks_passed": 10,
  "warnings": 1,
  "failures": 0,
  "warn_days": 30,
  "openssl": "OpenSSL 3.0.x",
  "server": {
    "subject": "subject=CN=api.example.com",
    "issuer": "issuer=CN=Example Intermediate CA",
    "sha256": "AA:BB:CC:DD...",
    "not_after": "Sep 01 00:00:00 2027 GMT"
  },
  "certificate_count": 3,
  "ca_count": 2,
  "leaf_count": 1
}
```

This can be consumed by:

* CI/CD pipelines
* Jenkins
* GitHub Actions
* Ansible
* monitoring systems
* shell automation
* Python scripts
* other JSON-processing tools

For example:

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt \
  --json | jq .
```

---

# CI/CD Example

A pipeline can fail when certificate validation fails:

```bash
set +e

./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt

RC=$?

if [[ "$RC" -eq 1 ]]; then
    echo "Certificate validation failed"
    exit 1
fi

if [[ "$RC" -eq 2 ]]; then
    echo "Certificate validation passed with warnings"
fi

exit 0
```

If warnings should also fail the pipeline:

```bash
if [[ "$RC" -ne 0 ]]; then
    echo "Certificate validation did not pass cleanly"
    exit "$RC"
fi
```

---

# Recommended Certificate Bundle Format

For a typical TLS server, use:

```text
server.crt
    |
    +-- Intermediate CA 1
            |
            +-- Intermediate CA 2
```

The root CA should normally be maintained separately.

Example:

```text
tls.crt
tls.key
rootCA.crt
```

Where:

```text
tls.crt
  ├── Server certificate
  ├── Intermediate CA 1
  └── Intermediate CA 2

rootCA.crt
  └── Trusted Root CA
```

---

# Example: OpenShift TLS Secret

For an OpenShift TLS secret, the certificate chain commonly exists in:

```bash
tls.crt
```

and the private key in:

```bash
tls.key
```

You can extract and validate the certificate:

```bash
oc get secret my-tls-secret \
  -n my-namespace \
  -o jsonpath='{.data.tls\.crt}' |
  base64 -d > tls.crt
```

Extract the private key:

```bash
oc get secret my-tls-secret \
  -n my-namespace \
  -o jsonpath='{.data.tls\.key}' |
  base64 -d > tls.key
```

Then:

```bash
./cert-validator.sh \
  --bundle tls.crt \
  --key tls.key \
  --root rootCA.crt
```

For security, remove temporary extracted keys after validation:

```bash
rm -f tls.key
```

---

# Troubleshooting Examples

## Private Key Mismatch

Output:

```text
[FAIL] Private key does NOT match server certificate
```

Check the certificate public key:

```bash
openssl x509 \
  -in server.crt \
  -pubkey \
  -noout
```

Check the private key:

```bash
openssl pkey \
  -in server.key \
  -pubout
```

They should represent the same public key.

---

## Missing Intermediate

A common failure is:

```text
error 20 at 0 depth lookup:
unable to get local issuer certificate
```

This generally indicates that the issuer required to build the chain is not available in the supplied intermediate set or trusted CA set.

Check:

```bash
openssl x509 \
  -in server.crt \
  -noout \
  -issuer
```

Then compare with the intermediate:

```bash
openssl x509 \
  -in intermediate.crt \
  -noout \
  -subject
```

The issuer/subject relationship should correspond.

---

## Wrong Root CA

If the chain fails despite having the expected intermediates, verify the root:

```bash
openssl x509 \
  -in rootCA.crt \
  -noout \
  -subject \
  -issuer \
  -fingerprint \
  -sha256
```

Compare the root fingerprint with the expected CA certificate.

---

## Expiring Certificate

Use a larger warning window:

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt \
  --warn-days 90
```

---

# Security Considerations

The utility processes private-key files.

The script:

* does not print the private key
* does not copy the private key into the temporary directory
* uses a restrictive `umask`
* uses a randomly generated temporary directory
* removes the temporary directory on exit
* supports cleanup on normal termination and signals

Recommended permissions:

```bash
chmod 600 server.key
```

Avoid running the validator with unnecessarily broad permissions.

Do not commit private keys to Git.

For example, add:

```gitignore
*.key
*.pem
*.p12
*.pfx
```

to `.gitignore` where appropriate.

If certificate files need to be committed for testing, use test/demo certificates and never production private keys.

---

# Recommended Repository Structure

A simple repository structure:

```text
certificate-chain-validator/
├── cert-validator.sh
├── README.md
├── LICENSE
├── .gitignore
└── examples/
    ├── README.md
    └── test-certs/
```

Example:

```text
.
├── cert-validator.sh
├── README.md
├── LICENSE
├── .gitignore
└── examples/
```

---

# .gitignore

Recommended:

```gitignore
# Private keys
*.key
*.pem
*.p12
*.pfx

# Temporary files
*.tmp
*.log

# macOS
.DS_Store

# IDE
.vscode/
.idea/
```

If you want to commit example certificates, place only deliberately generated test certificates under:

```text
examples/test-certs/
```

and explicitly allow them in `.gitignore` if necessary.

---

# Production Usage Recommendations

Before using the validator in production automation, test it against:

1. Valid server + intermediate + root
2. Expired server certificate
3. Not-yet-valid certificate
4. Expired intermediate
5. Missing intermediate
6. Incorrect intermediate
7. Incorrect root
8. Private-key mismatch
9. Multiple leaf certificates
10. Duplicate certificates
11. Root included in bundle
12. SAN mismatch
13. Hostname mismatch
14. IP SAN mismatch
15. Missing SAN
16. Missing EKU
17. SHA-1 certificate
18. Cross-signed certificate chain
19. Multiple intermediate certificates
20. RSA and ECDSA certificates

---

# Design Philosophy

The validator intentionally separates different types of validation.

```text
                    Certificate Validator
                            |
        +-------------------+-------------------+
        |                   |                   |
   Structure           Cryptography          Policy
        |                   |                   |
   PEM format          Chain validation     SAN
   Leaf detection      Signature chain      EKU
   Duplicates          Trusted root         Key Usage
   Root detection                           Expiry
                                             Algorithms
```

The actual cryptographic chain validation is delegated to OpenSSL rather than attempting to implement X.509 path validation in Bash.

This is important because certificate path building can involve:

* multiple intermediates
* cross-signing
* alternative trust paths
* certificate constraints
* key usage
* basic constraints
* signature verification
* trust anchors

OpenSSL remains the authoritative validation engine for these operations.

---

# Limitations

This is a Bash/OpenSSL validation utility and is not intended to replace a full TLS scanner or PKI management platform.

It does not currently perform:

* live TLS handshake testing
* OCSP validation
* CRL revocation checking
* certificate transparency checking
* remote endpoint certificate retrieval
* automated certificate renewal
* ACME management
* complete PKI policy compliance

For live endpoint testing, the certificate files can first be retrieved using tools such as:

```bash
openssl s_client
```

and then passed to this validator.

---

# Future Enhancements

Potential future improvements include:

* `--strict` policy mode
* OCSP validation
* CRL validation
* live endpoint mode
* `--server HOST:PORT`
* certificate chain extraction directly from TLS endpoints
* JSON schema/versioning
* JUnit output for CI/CD
* Prometheus-compatible metrics
* configurable policy file
* configurable minimum RSA/ECDSA key sizes
* configurable allowed signature algorithms
* certificate renewal-date reporting
* Kubernetes/OpenShift Secret integration
* automated certificate inventory
* Nagios/monitoring exit-code integration

---

# Quick Reference

### Basic bundle validation

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt
```

### Separate certificates

```bash
./cert-validator.sh \
  --cert server.crt \
  --intermediate intermediate.crt \
  --key server.key \
  --root rootCA.crt
```

### Hostname validation

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt \
  --hostname api.example.com
```

### IP validation

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt \
  --ip 10.10.10.20
```

### 90-day expiry warning

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt \
  --warn-days 90
```

### JSON output

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt \
  --json
```

### Check result in shell

```bash
./cert-validator.sh \
  --bundle fullchain.pem \
  --key server.key \
  --root rootCA.crt

echo $?
```

Exit codes:

```text
0 = PASS
1 = FAIL
2 = PASS WITH WARNINGS
3 = USAGE ERROR
4 = INPUT/PARSING ERROR
```

---

# License

Add the appropriate license for your organization/project.

For example:

```text
MIT License
```

or:

```text
Apache License 2.0
```


