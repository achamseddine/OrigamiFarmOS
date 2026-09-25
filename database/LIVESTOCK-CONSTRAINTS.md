# Livestock Integrity & Validation Matrix

Database constraints should enforce what PostgreSQL can prove locally; domain services enforce contextual rules in the same transaction.

| Rule | DB | Domain |
|---|---|---|
| Animal has farm/species/sex | NOT NULL/FK | yes |
| Breed belongs to species | composite/trigger possible | mandatory |
| Location belongs to farm | composite/trigger possible | mandatory |
| Stage/profile species compatible | partial relational | mandatory |
| Identifier normalized | stored value | normalizer service |
| Identifier uniqueness scope | indexes where possible | mandatory |
| No overlapping state ranges | exclusion constraint | mandatory |
| Group quantity never negative | CHECK | mandatory |
| Same farm animal/group membership | composite/trigger | mandatory |
| Same species membership | possible trigger | mandatory |
| Exclusive group type overlap | difficult | mandatory |
| No self relationship | CHECK | mandatory |
| Pregnancy capability | later reproduction DB cannot prove alone | mandatory |
| Species correction with history | no simple CHECK | privileged workflow |
| Offline duplicate resolution | no | sync workflow |

## Cross-farm FK hardening
Where a child stores `farm_id` for security/query efficiency, prefer composite unique keys such as `unique(id, farm_id)` on parent and composite FKs `(animal_id, farm_id)` where practical. This makes cross-farm references impossible at the database layer rather than relying only on application validation.

Apply this consistently during executable migration generation.

## Effective ranges
For PostgreSQL, consider `tstzrange(effective_from,effective_to,'[)')` exclusion constraints with `btree_gist` to prevent overlapping periods for:
- animal state by animal + state_type;
- group membership by group + animal;
- external alias validity where required.

Do not introduce extensions without an ADR/migration note.
