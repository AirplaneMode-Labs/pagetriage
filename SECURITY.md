# Security policy

## Reporting a vulnerability

Email jtushar53@gmail.com with a description, the affected version or commit, and steps to reproduce.
Please do not open a public issue for a vulnerability. You will get an acknowledgement within 7 days.

We follow a 90-day coordinated disclosure window: we aim to fix and publish within 90 days of the
report, and ask reporters to hold details until a fix is released or the 90 days have passed,
whichever comes first.

## Supported versions

| Version | Supported |
|---|---|
| none released | no package or tag has been published; fixes land on `main` |

Until a first release is tagged, only the `main` branch is supported, and the repository's
`[workspace.package] version` stays `0.1.0`.

## Scope

pagetriage is a library and command-line tool that parses untrusted scanned images and PDFs. Bugs
that make it panic, hang, allocate without bound or read outside an image buffer on crafted input are
in scope. The browser demo (`site/`) and the Python and WebAssembly bindings are in scope.

## Test key material

Other Airplane Mode Labs repositories contain the RFC 8032 section 7.1 Ed25519 test vector as public
test data; it is not a secret and must never be trusted outside tests. pagetriage contains no key
material at all: nothing in this repository signs or verifies anything yet (signed release artefacts
are an open item in [docs/release.md](docs/release.md)).

## Telemetry

pagetriage collects no telemetry and makes no network requests from the library, the command-line
tool, the Python module, the WebAssembly package or the demo page, so there is nothing to opt out of.
