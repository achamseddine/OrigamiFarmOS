# Milk safety: what v0.8.5 changes for existing milk records, and the review

Audit 2026-11-25 (I-3, I-15), [ADR-005](../../architecture/ADR-005-MILK-SAFETY-AT-THE-MILKING-TIME.md), migration `e8a0c2e4b6d9`.

## 1. What the migration does to existing data: nothing it would have to undo

| Data | After the migration |
|---|---|
| Every existing `milk_records` row | `withdrawal_check = 'unchecked'`, `release_status = 'saleable'`. The litres, session, time and destination are unchanged. |
| Milk tank | Same balance as before: older stored milk still counts. |
| Handovers, milk sales, payments, Sales & Finance, reports | Unchanged. No sale is touched, now or later. |
| `animals.withdrawal_known_since` | Set to the migration time for animals with a withdrawal on their record. This is true: the withdrawal was already there then, so it began no later. |

From the migration onwards, every new milking, every correction and every offline replay is judged at its own milking time (ADR-005). Unsafe milk is accepted only as withheld; uncertain milk is held. Neither reaches the saleable tank.

## 2. The consequence for older records

Before v0.8.5, the check compared the animal's withdrawal date with **now**. So a milking entered *after* a withdrawal ended, for a day *inside* it, was stored as saleable (I-3). Such records may exist on a farm server that ran earlier versions, and their milk may already have gone to the collector or been sold. v0.8.5 **does not** reclassify them automatically. Doing so would:

- change the tank balance retroactively (possibly below what was then sold);
- present a guess about what physically happened as a fact.

Instead, the dated history is applied to them **read-only**, and a person decides.

## 3. The review (manager and veterinarian, once after upgrading)

1. `GET /api/v1/production/milk-safety/review?days=365` (any user who sees Milk or Animal Health). For every older record (`unchecked`, not withheld) it lists:
   - the cow, the milking time, the litres and the destination;
   - `withdrawal_check`: `withdrawal` (a recorded dose or treatment covered it) or `uncertain` (only the animal's record or a reversed dose);
   - the windows, with the medicine, start and end.

   Totals: `withdrawal_l` and `uncertain_l`. The same check in SQL, for a farm without the API at hand, is §5.
2. For each finding:
   - **It went into the tank and was sold or collected** (the usual case: the collector takes the milk after each milking). It is a food-safety incident to record and, where required, report. The record and the sale stay as they are (history is not rewritten). If the farm wants the record to say the milk should not have been sold, the manager posts a correction of its destination to `withheld` (`POST /production/milk/{id}/correct`, with the reason). That correction is audited and moves the litres out of the tank figure from then on; it does not change the sale.
   - **The withdrawal on record was wrong** (a dose recorded on the wrong animal, a wrong date). The veterinarian corrects the dose or treatment record. The finding disappears on the next review.
   - **The milk was actually withheld but recorded as stored.** Correct its destination to `withheld`.
3. Milk entered from now on that cannot be confirmed is **held**: Milk page → *Milk held for review*, or `GET /production/milk-held`. A veterinarian or the farm manager releases it (it then counts in the tank) or withholds it, giving the reason (`POST /production/milk/{id}/review`). Milk a recorded withdrawal covers cannot be released (409).
4. A dose or treatment entered later with a start in the past moves any milk it covers from saleable to held, and notifies the manager and veterinarian (*N L of Luna's milk held for review*). The tank figure drops by those litres; a sale already made is not changed. Step 2 applies to the part that was sold.

## 4. Lactations (I-15)

Milk is now accepted for any time a lactation episode covers, including one that has since ended. Nothing in existing data changes. Older milk records have no `lactation_episode_id`; new ones do.

## 5. SQL check (read-only, PostgreSQL and SQLite)

Older milk that a recorded *treatment* window covers (doses are listed by the API, which also resolves group membership):

```sql
SELECT m.id, m.animal_id, m.recorded_at, m.session, m.liters, m.destination, t.medication, t.start_at, t.withdrawal_until
FROM milk_records m
JOIN treatments t ON t.entity_type = 'animal' AND t.entity_id = m.animal_id
WHERE m.withdrawal_check = 'unchecked'
  AND m.destination <> 'withheld'
  AND t.withdrawal_until IS NOT NULL
  AND m.recorded_at >= t.start_at AND m.recorded_at < t.withdrawal_until
ORDER BY m.recorded_at;
```

Milk that is held, and milk in the tank by status:

```sql
SELECT release_status, withdrawal_check, COUNT(*), SUM(liters)
FROM milk_records
WHERE destination = 'stored'
GROUP BY release_status, withdrawal_check;
```

The tank balance counts only rows with `release_status IN ('saleable', 'released')`.
