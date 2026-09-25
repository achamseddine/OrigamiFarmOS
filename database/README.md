# Origami FarmOS Database

This directory is the canonical relational database design for implementation.

## Read order
1. `SCHEMA-MAP.md`
2. `FOUNDATION-SCHEMA.md`
3. `FOUNDATION-ERD.md`
4. `REFERENCE-DATA.md`
5. Later domain schemas: livestock, inventory, feed, reproduction, health, production, procurement, etc.

The database implements the semantics in `handbook/02-Ontology.md`, behavior in `handbook/03-Behavioral-Model.md`, and conventions in `architecture/DATABASE-ARCHITECTURE.md`.

## Rule
Do not infer a different physical schema merely because a conceptual entity exists in the ontology. Physical relational design is specified here. Schema changes require migrations and documentation updates.
