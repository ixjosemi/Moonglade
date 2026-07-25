# Security Policy

## Supported versions

Moonglade is currently pre-1.0. Security fixes are applied to the latest release and the default branch.

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** flow under the repository's Security tab. Do not open a public issue for suspected vulnerabilities or include secrets, private paths, session content, or proof-of-concept payloads in public discussions.

Include the affected version, macOS version, impact, reproduction steps, and any suggested mitigation. You should receive an acknowledgement within seven days. Please allow time for investigation and a coordinated fix before disclosure.

## Security model

- Moonglade runs as the current macOS user and has no privileged helper.
- It has no network client, server, analytics, account system, or cloud storage.
- Terminal focusing uses macOS Automation and only occurs after a user action.
- Integration state is local metadata and is protected with user-only filesystem permissions.
- Hooks and plugins are not a security boundary: another process running as the same user can modify local files or spoof state.

Only source builds are provided until a Developer ID-signed and notarized release pipeline is available. Never install an unsigned binary obtained from an untrusted third party.
