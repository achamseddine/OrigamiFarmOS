# ADR-006 — One feeding policy for the plan, the reports and the forecast

**Status:** Accepted (v0.8.6; no migration)
**Audit:** 2026-11-25 I-4 (AF-01), I-5 (AF-05), I-6 (NEW-6)
**Amends:** docs/GENERIC-FEED-ARCHITECTURE.md §9 and §11 (they now point here). Consistent with database/FEED-SCHEMA.md §11 ("individual overrides do not erase group assignments"), §13 ("offered, consumed estimate and waste are distinct") and §19.

## Context

The daily plan, the subject plan, the costs, the usage report, the forecast and the lot trace each decided on their own what a head is fed, what counts as fed, and what "today" is:

| Question | Before v0.8.6 | Consequence |
|---|---|---|
| How many heads does a group's ration feed? | All its members, always. A member with her own program also had her own line. | A cow on her own ration was planned twice (AF-01). |
| A cow in two groups with rations (her herd and "Pregnant cows")? | Both groups counted her. | Two base rations for one cow. |
| Override on a cow fed with her group? | Her line added nothing; the group's line kept the group quantity for her. | The plan disagreed with her own profile. |
| Is a refusal fed? | `_fed_totals` (the subject's *fed 7 days*), `cost_summary` quantities and the lot trace counted every event type. The daily plan and the reports counted only offered/delivered. | 2 kg refused showed as 2 kg more fed (AF-05); reports disagreed with each other. |
| What is "today"? | `daily_plan` used the UTC date and UTC midnight; history and cost windows were rolling 24-hour slices; the forecast's history read the day a movement was typed in. | A feeding at 00:30 in Beirut (22:30 UTC) fell on the previous day (NEW-6); a backdated feeding counted on the day it was entered. |

## Decision

### 1. Base allowance — exactly one per head

A head's base ration is the most specific one in force at the time asked about (`feeding_program_service.base_ration`):

1. its own explicit program;
2. else the program of a **status group** it is in (a group with a `membership_rule` — pregnant, not pregnant, in milk, dry — that follows the herd records);
3. else the program of its **exclusive group** (herd / flock / pen / batch);
4. else the program of any other group it is in (a cohort).

Ties within a level go to the group named first (then its id). The groups not applied are listed and the animal's plan says so (*Bella is also in Dairy Herd, which has its own ration; she is fed Pregnant cows'*).

A group's line counts only the heads its own ration feeds (`group_heads`): its head count — its members at that time for a `MEMBERSHIP_DERIVED` group, its counted total for a counted flock — less each member whose base ration comes from elsewhere (`own_program`, `other_group`) or whose ration is adjusted for her (`own_override`, `own_restriction`). The excluded members are named on the line (`excluded_heads`, `member_count`). A group with no ration of its own excludes nobody.

### 2. Adjustments

| Type | Meaning | On the plan |
|---|---|---|
| `override` | **Replaces** one product's daily quantity per head. The group's own overrides apply to the heads it feeds; an animal's apply to her, after the group's (the most specific wins). An override of a product not in the ration changes nothing and says so (a feed on top is a supplement). | An animal with her own override is planned on her own line, `basis: adjusted_group_ration` — her group's ration with her quantity — and is not in the group's count. |
| `supplement` | **Adds** a quantity per head on top of the base. A group's supplements are its heads'; an animal's are hers. | An animal fed her group's ration as it is stays in the group's count; her line, `basis: supplement_only`, carries only the supplement. |
| `restriction` | **Removes** a product. A restriction of *any* group she is in binds her (the daily plan, her plan and `POST /feeding-events`). | Her own restriction plans her on her own line, without the product (and without a supplement of it). |

### 3. Fed — only what moved stock

| Event | Stock | Counted as |
|---|---|---|
| `offered`, `delivered` | Issued from the lots (FIFO or the named lot) | **fed**; costed; exposure on the lot trace. A measured `quantity_consumed` is shown as *consumed*. |
| `refusal` | Moves nothing | **refused** — shown apart (`refused_7d`), never fed, never costed, not an exposure, not a feeding round on the tablet. |
| `consumed_estimate` | Moves nothing | **consumed** — an intake estimate, never fed. |

`programs.STOCK_MOVING = ("offered", "delivered")` is the one definition. It is used by the daily plan (`fed`, `fed_today`), the subject plan (`fed_7d`, `feed_cost_7d`), `cost_summary`, the feed report, the finance P&L, the lot trace and Feed Performance Intelligence (which already did). The forecast's history and the reconciliation read the inventory ledger, where only stock-moving events have movements. Reversed events and reversals are excluded everywhere (`status = 'recorded'`).

A group's feeding stays the group's: it is never spread over its heads, so no animal's own line or history is credited with a share of it. Its `head_count` defaults to the heads its ration feeds; the feeder may give the heads actually fed (a partial feeding).

### 4. Days — the farm's calendar

`app/services/farm_time.py` is the one definition: a day is local midnight to the next local midnight in `farms.timezone` (Asia/Beirut), built from the date in the zone, so a daylight-saving day is 23 or 25 hours long (Lebanon changes at midnight: 2026-03-29 starts at 01:00; 2026-10-24 has two 23:00–23:59). Used by:

- `GET /feeding-plan/today` — today by default, any past day with `?day=YYYY-MM-DD` (yesterday, a backdated record's day). The response carries `date`, `timezone`, `from`, `to` (UTC). For a past day, the programs, memberships and assignments are those in force at the end of that day — including an assignment ended or superseded since. Fed subjects no line plans are listed in `unplanned_fed`, so nothing that left the store is unaccounted;
- the subject plan's *last 7 days* and `feeding-history?days=N` (N farm days, today included);
- `GET /feed-costs?days=N` (N farm days);
- the forecast's history (the last 14 **whole** farm days, yesterday and back; a feeding counts on the day it was given — its `occurred_at` — not the day it was typed in);
- Feed Performance's effective feed value head-days;
- the period reports (already farm-local since v0.7.9).

The tablet and the web app take "today" from the plan's `from`/`to` (`onFarmToday`), so a browser or tablet set to another zone shows the farm's day; with no plan loaded yet they use the device's day as before.

## Numeric example (the demo farm, through the API, on the code before and after; `test_AF01` and `test_AF05` assert the after column)

The Dairy Herd: Bella, Luna, Clover on DAIRY-HIGH (2 feedings × 10 kg dairy mix, 3 kg alfalfa, 3 kg concentrate = 20 / 6 / 6 kg per head per day); Bella has a +2 kg concentrate supplement. Clover is put on DAIRY-MEDIUM (16 / 6 / 4).

| Figure | Before | After | Right answer |
|---|---|---|---|
| Herd line head count | 3 | **2** (member count 3, Clover named) | 2 |
| Dairy mix planned for the three cows | 60 + 16 = **76 kg** | 40 + 16 = **56 kg** | 20 + 20 + 16 = 56 |
| Alfalfa (cows) | 18 + 6 = 24 kg | 12 + 6 = **18 kg** | 18 |
| Concentrate (cows) | 18 + 4 + 2 = 24 kg | 12 + 4 + 2 = **18 kg** | 6 + 2 + 6 + 4 = 18 |
| Days of cover / reorder demand for dairy mix | 76 kg/day | **56 kg/day** | 56 |

Then 33 kg of dairy mix is delivered to the herd and 2 kg is recorded refused:

| Figure | Before | After |
|---|---|---|
| Stock moved by the refusal | 0 | 0 |
| Herd's *fed, last 7 days* | 390 + 33 + 2 = **425 kg** | 390 + 33 = **423 kg**, *refused 2 kg* shown apart |
| Feed costs, dairy mix quantity | +35 kg | **+33 kg** |
| Today's plan, *fed today* | +33 kg | +33 kg (unchanged — it already filtered) |

A feeding of 7 kg alfalfa to the stallion at **00:30 on 25 November in Beirut** (22:30 UTC on the 24th), seen on the 25th:

| Figure | Before | After |
|---|---|---|
| Today's plan (25 Nov), alfalfa *fed today* | +0 kg (counted from UTC midnight) | **+7 kg** |
| `?day=2026-11-24` | not available | the feeding is not there (it is the 25th) |

## Consequences

- No data changes and no migration: the policy is applied when reading. Past days read back with the assignments in force then.
- A farm that put a cow on her own ration while leaving her in a herd sees the herd's planned total drop by her share — the total it should always have been. Reorder suggestions follow.
- Group feedings recorded from now on default to the heads the ration feeds. Older events keep the head count they were recorded with.
- Remaining, documented, not changed here: activating a new version of a program moves its assignments to the new version in place (`activate_program_version`), so a past day before the activation is planned with the new version's quantities; Feed Performance Intelligence's multi-day evaluation windows (`feed_performance_service._start_of`) still begin at UTC midnight (≤ 3 h at each window edge on 7–28 day windows); `GET /feeding-events?days=N` (a list for the tablet's cache) is a rolling window. Neither is a daily figure.
- Tests: backend `tests/test_feeding_plan_policy.py`, run again on PostgreSQL 16 by `tests/test_feeding_plan_policy_pg.py` (AF-01, supplements, overrides, restrictions, a status group, two cohorts, a counted flock, demand and cover; AF-05 across plan, subject plan, costs, report, lot trace and forecast history; NEW-6, DST spring and autumn, yesterday, a past day, partial group feeding, history and cost windows); app `test/records/feeding_plan_policy_test.dart`.
