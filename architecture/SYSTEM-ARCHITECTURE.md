# System Architecture

## Architectural style
Origami FarmOS begins as an offline-first **modular monolith** with clean domain boundaries. This minimizes operational complexity while retaining future extraction paths.

```text
Web Management ─┐
                ├── API/Auth ── Modular Application ── PostgreSQL
Mobile/Tablet ──┘                    │
                                    ├─ Domain Events
                                    ├─ Workflow/Notifications
                                    └─ Integration Adapters
```

## Initial modules
Platform/IAM; Farm/Location; Livestock; Reproduction; Health/Welfare; Feed/Nutrition; Inventory; Procurement; Production; Crops; Assets; Laboratory/Quality; Finance/Costing; Traceability/Compliance; Workflow/Notifications; Analytics/Integration.

A module owns its authoritative tables and behavior. Cross-module changes use public application interfaces/events, not direct writes.

## Deployment
Start with a single application deployment plus PostgreSQL and supporting infrastructure required by the chosen implementation framework. Keep background workers logically separable but avoid premature distributed services.

## Offline
Mobile critical workflows must work without connectivity. Local operations receive stable operation IDs and sync through server APIs. The server remains authoritative and can accept, reject or flag conflicts after validation.

## Scalability
Prefer stateless API nodes, indexed relational queries, asynchronous processing for slow side effects and read projections for heavy dashboards. Do not introduce distributed complexity until measured requirements justify it.
