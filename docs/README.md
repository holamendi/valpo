# Valpo Documentation

Valpo's root [README](../README.md) is the user-facing starting point. This folder contains detailed user guides plus product, architecture, roadmap, and implementation notes.

## User Guides

- [valpo-cli.md](./valpo-cli.md) is the generated canonical command-line guide.
- [valpo-api.md](./valpo-api.md) explains API v1 authentication, validation, and errors; [openapi.yaml](./openapi.yaml) is the OpenAPI 3.1 contract.
- [valpo-project-manifest.md](./valpo-project-manifest.md) defines the current `valpo.toml` schema and reconciliation behavior.
- [valpo-managed-services.md](./valpo-managed-services.md) describes managed-service behavior and the broader service roadmap.
- [valpo-release-lifecycle.md](./valpo-release-lifecycle.md) defines release identity, schema compatibility, dedicated-host ownership, and the staged upgrade/recovery contract.
- [../packaging/README.md](../packaging/README.md) covers installation, host configuration, and VPS smoke tests.

## Product And Engineering Notes

- [valpo-product-brief.md](./valpo-product-brief.md) describes the product idea, audience, principles, scope, and non-goals.
- [valpo-technical-architecture.md](./valpo-technical-architecture.md) describes the implemented host foundation and the proposed long-term architecture.
- [valpo-extensibility-and-positioning.md](./valpo-extensibility-and-positioning.md) compares reference projects and defines Valpo's extensibility boundaries.
- [valpo-roadmap.md](./valpo-roadmap.md) tracks completed phases and planned work from the single-server core to a multi-server dashboard.
- [valpo-architecture-decisions.md](./valpo-architecture-decisions.md) captures initial high-level decisions in lightweight ADR form.
- [development.md](./development.md) covers local setup, checks, generated documentation, and the permanent schema/release metadata policy.
