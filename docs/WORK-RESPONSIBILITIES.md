# Work responsibilities — who looks after what

**Status (2026-11-13):** implemented on `claude/gifted-davinci-mu9fjj` (migration `c3e5a7b9d1f4`).

A farm worker is responsible for certain animals or crops and the duties
there — milking and recording the milk, feeding and recording the feed,
marking observations. Module permissions (Settings > Employees >
*Responsibilities*) say which screens a person may use; a **work
responsibility** says what they look after.

## Model

`work_responsibilities`: `user_id`, `scope_type` (`animal` | `group` |
`species` | `field`), `scope_id` (the animal / group / field id or the
species code), `duties` (`milking`, `feeding`, `observation`,
`health_care`, `egg_collection` for animals; `crop_care`, `harvest`,
`observation` for a field), `status` (`active` | `ended`), `valid_from`,
`valid_to`, `notes`, audit columns. Ended, never deleted.

| Duty | Access it needs |
|---|---|
| milking | Milk production |
| feeding | Feed & nutrition |
| observation | Animals |
| health_care | Animal health |
| egg_collection | Egg production |
| crop_care | Agriculture |
| harvest | Produce & harvest |

Assigning a responsibility adds the missing module grants as ordinary
`user_module_permissions` rows (view, create, edit) and an audit entry
saying so; ending one does not revoke access silently — the manager does
that on the permission matrix. A responsibility routes the work; it does not
hide the rest of the farm from someone whose grants already show it.

## API

- `GET /employees/{id}/responsibilities` (Employees view) — `include_ended`.
- `POST /employees/{id}/responsibilities` (Employees assign) — `scope_type`,
  `scope_id`, `duties`, `notes`; returns the row and `modules_granted`.
  409 for the same scope twice, 422 for a duty that does not fit the scope.
- `POST /employees/{id}/responsibilities/{rid}/end` (Employees assign).
- `GET /me/responsibilities` — the signed-in person's own, with the animals
  each covers today (a group's current members, a species' animals).

Every assignment and end is an event (`responsibility_assigned`,
`responsibility_ended`) and an audit entry.

## Tablet

- Settings > Employees: *Animals & duties* on each active employee — the
  current responsibilities (end), and a form: scope type, the group /
  animal / species / field, the duties, notes.
- My Day: *My animals & duties* for whoever has responsibilities — each
  scope, its duties with today's progress counted from the records (milked
  n of m cows in milk, fed), *Scan & record*, *Feed the group*, and the
  animals as chips that open their profile.
- Offline: assignments queue and show at once (cache rules for both writes).

## Demo

Karim (animal-care worker) looks after the Dairy Herd: milking, feeding,
observations.
