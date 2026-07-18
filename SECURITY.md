# Security policy

## Secrets

DeepSeek API keys and other credentials must never be committed, uploaded as build artifacts, written to release notes or included in diagnostic data.

The repository ignores common secret and signing-key formats. This is a preventive control, not a substitute for reviewing every change before publication.

## Release verification

Each GitHub-built executable is published with:

- a SHA-256 entry in `SHA256SUMS.txt`;
- a GitHub Artifact Attestation bound to the repository, commit and workflow run.

These controls establish integrity and build provenance. They are not Authenticode publisher validation.

## Reporting

Use GitHub's private security advisory feature for vulnerabilities that should not be disclosed publicly before a fix is available.
