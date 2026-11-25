# ADR-005 — Milk safety is judged at the milking time, from dated facts

**Status:** Accepted (v0.8.5, migration `e8a0c2e4b6d9`)
**Date:** 2026-11-25
**Fixes:** audit 2026-11-25 (default branch `9acaba3`) **I-3** (withdrawal judged at "now", so backdated milk inside a past withdrawal could be stored and sold) and **I-15** (backdated milk refused because the animal is dry *today*, though she was in milk at the milking).
**Amends:** `database/PRODUCTION-SCHEMA.md` §4, §8 and §10.

## Context

What the design said, and what the code did:

| Design (PRODUCTION-SCHEMA) | Actual model before v0.8.5 | Consequence |
|---|---|---|
| §4 `milk_session.withdrawal_restricted`; §10 "production and disposition are distinct… the record captures 24 L while disposition marks it restricted and prevents sale/eligible tank transfer" | No `milk_session` table. `milk_records.destination` (stored, sold, processed, consumed, withheld) is the disposition; the tank is Σ `stored`. Withdrawal was the animal's single `withdrawal_until` compared with **now**. | Milk entered late for a day inside a withdrawal that has since ended was accepted as `stored` and could be sold (I-3). A treatment with a shorter withdrawal overwrote a longer one on the animal. The offline sync push created milk records with no check at all. |
| §8 "a milk record is accepted only for an animal that is in milk (an **active** episode)" | The same rule in `ensure_milk_allowed`. | Milk noted on paper before yesterday's dry-off could not be entered (I-15). |
| §8 "milk records can reference the effective lactation through a future optional FK" | No link. | — |

The veterinary facts the decision needs already exist and are dated:
`medication_administrations` (`administered_at`, `withdrawal_milk_until`, `status` recorded | reversed, subject an animal or a group), `treatments` (`start_at`, `withdrawal_until`, an animal or a group), `animal_group_memberships` (`valid_from`, `valid_to`) and `lactation_episodes` (`started_at`, `ended_at`).

## Decision

1. **One judgement, at the milking's own timestamp** (`backend/app/services/milk_safety_service.py`), used by every path that creates or changes a milk record: `POST /production/milk`, corrections (direct and approved), the offline `POST /sync/push`, and the held-milk review. It reads the animal's history only; the day the record is *entered* plays no part. Given the same history, the same milking always gets the same answer, whether it is entered at the parlour, from a paper sheet, or replayed by a tablet that was offline.

2. **Withdrawal windows come from dated facts.** Each window is one of:
   - an administration to her, or to a group she belonged to at `administered_at`: `administered_at → withdrawal_milk_until`;
   - a treatment to her or her group: `start_at → withdrawal_until`.

   Overlapping medicines are separate windows, and the milk is clear only outside all of them. The windows are the authorised rules carried by the doses and prescriptions. **Nothing here computes, shortens or invents a window, a diagnosis or a clearance.**

3. **Three answers:**

   | Answer | Meaning | Allowed destination |
   |---|---|---|
   | `clear` | no window covers the milking | any |
   | `withdrawal` | a recorded window covers it | only `withheld`; anything else is refused (422) |
   | `uncertain` | only an uncertain window covers it | kept, but **held for review** |

   Uncertain windows are:
   - an administration recorded and then reversed (a reversal does not prove the animal was not dosed);
   - the animal's stored `withdrawal_until` when no dated milk window explains it, for milk before the server first held that value (`animals.withdrawal_known_since`).

   From `withdrawal_known_since` onwards that stored withdrawal counts as recorded, so a live entry is refused exactly as before. A meat-only window does not explain the stored withdrawal for milk, so a meat withdrawal stays on the milk as it always has. **No milk is cleared that was blocked before.**

4. **Disposition and saleability are separate** (this implements §10 without a `milk_session` table). `milk_records.destination` stays where the milk went. A new `release_status` records whether it may be sold:

   | `release_status` | Meaning |
   |---|---|
   | `saleable` | clear, and the destination is not withheld |
   | `held` | uncertain, and not withheld |
   | `released` | held, then released by a reviewer |
   | `not_for_sale` | withheld |

   `withdrawal_check` records the judgement and `safety_note` records why; the client never sets either. **The tank counts only `stored` milk that is `saleable` or `released`**, and so do the handovers to the collector and every milk sale (sales draw on the tank). Unsafe or uncertain milk never reaches the saleable tank.

5. **Review authority.** Held milk is released or withheld only by the roles that diagnose and decide on treatment (owner, manager, veterinarian, as `health_case_service.DIAGNOSTIC_ROLES`), with a written reason kept on the record, in the audit log and in the event stream. The server refuses to release milk that a *recorded* window covers (409). A wrong prescription window is corrected on the treatment or dose by the veterinarian, never cleared from the milk.

6. **Facts recorded later.** A dose or treatment entered with a start in the past reaches milk already saved as saleable. That milk is moved to `held` (out of the tank), and the manager and veterinarian are notified. **No sale is changed**: a sale is a fact of what happened. Whether milk already sold was affected is for the people to decide (runbook).

7. **Lactation at the milking time** (amends §8). Milk belongs to the lactation episode that covers its timestamp, active or ended, from one day before `started_at` to `ended_at`. Milk after a dry-off, between two lactations, or before the first lactation is refused, with the dates. An animal milked before lactations were recorded (no episode, `lactating` true) is accepted as before. The record links the episode (`milk_records.lactation_episode_id`, the "future optional FK" of §8). The milk capability check is unchanged.

8. **Older records are reviewed, not rewritten.** Records made before v0.8.5 are `unchecked` and keep counting as they did (`saleable`). `GET /production/milk-safety/review` lists those that the dated history now places inside a window. It is read-only; see `docs/runbooks/MILK-SAFETY-REVIEW.md`.

## Consequences

- I-3: a 2-days-ago milking inside a withdrawal that ended yesterday is refused as stored or sold, and accepted only as withheld (`test_NEW3_…`). With only the animal's record to go on, it is held, not sold.
- I-15: a cow dried off yesterday can have milk entered from three days ago (in her ended lactation, and clear). Milk after the dry-off and milk before the lactation stay refused (`test_I15_…`).
- Overlapping treatments: a shorter withdrawal no longer cuts a longer one on the animal (`record_treatment`).
- The offline sync push no longer bypasses the checks.
- New endpoints:
  - `GET /production/milk-safety?animal_id&at` (forms ask before saving);
  - `GET /production/milk-held`;
  - `POST /production/milk/{id}/review`;
  - `GET /production/milk-safety/review`.

  `MilkRecordOut` gains the safety fields, and the milk report adds `held_l`.
- Cost: each milk check reads the animal's doses, treatments and memberships. That is a few indexed queries, acceptable at farm scale.
- Not covered: a `milk_session` table (§4) is still not introduced, and tank *location* is not modelled. Both remain future work under §4.
