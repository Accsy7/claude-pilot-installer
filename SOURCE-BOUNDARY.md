# Public source boundary

## Included

- `src/ClaudePilotSetup`: WPF installer source and embedded UI assets;
- `src/Engine`: self-developed orchestration, recovery, diagnostics and uninstall scripts;
- `src/Resources/MCP`: self-developed Word/Excel MCP scripts;
- `build/Build-PublicCore.ps1`: isolated build for the installer executable;
- `.github/workflows/build-and-attest.yml`: GitHub build, SHA-256 and provenance attestation.

## Explicitly excluded

- `vendor/` and every third-party offline payload;
- `_tools/`, local SDKs and package caches;
- `输出/`, delivery packages, ZIP files and acceptance artifacts;
- generated `bin/`, `obj/`, `build/publish/` and `artifacts/` directories;
- local reports, diagnostics, state, logs, backups and user data;
- signing certificates, private keys, API keys and credentials.

The public workflow builds only `ClaudePilotSetup.exe`. It does not reconstruct or attest the private offline resource package.
