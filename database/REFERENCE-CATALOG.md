# Database Baseline v1 — Reference Catalog

Reference data is platform-stable (UOM dimensions/UOMs/permissions), domain-governed (species, breeds, life stages, profiles, capabilities, production/crop/status codes), or farm-specific configuration.

Seed stable technical codes, keep labels/localization evolvable, use uppercase snake-case codes, retire rather than delete operationally used values, never hard-code reference UUIDs, and make seeds idempotent. Promote simple code sets to tables when localization, metadata, effective dating or external mappings justify it. Initial values remain in REFERENCE-DATA.md.
