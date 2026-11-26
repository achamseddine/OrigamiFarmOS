"""Employee work that waits for the farm manager (approval_models.py).

The farm's rule: employees enter the day's data — milk, feedings — but do
not buy feed, make a numbered mix or change a record on file without the
farm manager. Buying goes through purchase requisitions (procurement);
a mix or a correction made by someone without approval on its module is
kept here as a request:

  create  — the employee's version is checked now (so a mistake is heard
            while they are still at the cow) and stored; stock, mixes and
            records are untouched; the managers are notified.
  approve — someone with *approve* on the module runs the same service a
            manager would use directly; who asked and who approved are
            recorded on the result.
  reject  — with a reason; nothing changes. The employee is told either way.
  cancel  — the employee withdraws a request still pending.
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import ensure_stock_override, user_can
from app.core import permissions as perms
from app.core.record_time import not_in_future
from app.domain import approval_models as am
from app.domain import feed_models as fm
from app.domain import models
from app.repositories.base import ensure_utc, new_id, now, write_event
from app.schemas.approvals import FeedingCorrectionIn, MilkCorrectionIn
from app.schemas.feeding import QuickMixIn
from app.services import feed_batch_service as batches
from app.services import feed_inventory_service as inv
from app.services import feed_performance_service as perf
from app.services import feeding_program_service as programs
from app.services import milk_service
from app.services import routing_service as routing
from app.services.feed_inventory_service import FeedError

KIND_MODULE = {
    "feed_mix": perms.FEED_NUTRITION,
    "milk_correction": perms.MILK_PRODUCTION,
    "feeding_correction": perms.FEED_NUTRITION,
}
ROUTE = "approval_request"


class ApprovalError(FeedError):
    pass


def get(db: Session, request_id: str, farm_id: str) -> am.ApprovalRequest:
    req = db.get(am.ApprovalRequest, request_id)
    if req is None or req.farm_id != farm_id:
        raise ApprovalError("Request not found", 404)
    return req


def can_decide(db: Session, user: models.User, req: am.ApprovalRequest) -> bool:
    return user_can(db, user, req.module_code, perms.APPROVE)


def pending_for(db: Session, farm_id: str, target_id: str) -> am.ApprovalRequest | None:
    return db.scalar(select(am.ApprovalRequest).where(
        am.ApprovalRequest.farm_id == farm_id, am.ApprovalRequest.target_id == target_id, am.ApprovalRequest.status == "pending"))


def ensure_none_pending(db: Session, farm_id: str, target_id: str) -> None:
    """A record with a correction waiting is decided through that request,
    so two versions of it never compete."""
    waiting = pending_for(db, farm_id, target_id)
    if waiting is not None:
        who = db.get(models.User, waiting.requested_by)
        raise ApprovalError(f"{who.name if who else 'An employee'} asked to correct this record; approve or reject that request first.", 409)


# ------------------------------------------------------------------ create
def create(db: Session, user: models.User, *, kind: str, payload: dict, reason: str | None, target_id: str | None) -> am.ApprovalRequest:
    if kind not in KIND_MODULE:
        raise ApprovalError(f"kind must be one of {list(KIND_MODULE)}")
    module = KIND_MODULE[kind]
    if not user_can(db, user, module, perms.CREATE):
        label = perms.MODULES_BY_CODE[module].label_en
        raise ApprovalError(f"You do not have permission to create in {label}. Ask a farm manager to grant it.", 403)
    reason = (reason or "").strip() or None
    subject_type = subject_id = None
    if kind == "feed_mix":
        summary, payload = _check_mix(db, user, payload)
    elif kind == "milk_correction":
        if not reason:
            raise ApprovalError("Say why the milk record should be corrected.")
        summary, payload, animal = _check_milk(db, user, target_id, payload)
        subject_type, subject_id = "animal", animal.id
    else:
        if not reason:
            raise ApprovalError("Say why the feeding should be corrected.")
        summary, payload, event = _check_feeding(db, user, target_id, payload)
        subject_type, subject_id = event.subject_type, event.subject_id
    if target_id:
        ensure_none_pending(db, user.farm_id, target_id)
    req = am.ApprovalRequest(
        id=new_id(), farm_id=user.farm_id, kind=kind, module_code=module, status="pending", subject_type=subject_type, subject_id=subject_id,
        target_id=target_id, summary=summary[:300], payload=payload, reason=reason, requested_by=user.id, requested_at=now(),
    )
    db.add(req)
    db.flush()
    write_event(db, farm_id=user.farm_id, entity_type="approval_request", entity_id=req.id, event_type="approval_requested",
                payload={"kind": kind, "summary": req.summary, "target_id": target_id, "reason": reason}, created_by=user.id)
    _notify(db, req, [u for u in routing.recipients(db, user.farm_id, ROUTE) if u.id != user.id],
            title=f"Waiting for your approval: {req.summary}", description=f"Asked by {user.name}." + (f" Reason: {reason}" if reason else ""))
    return req


def _check_mix(db: Session, user: models.User, payload: dict) -> tuple[str, dict]:
    mix = QuickMixIn.model_validate(payload)
    not_in_future(mix.produced_at, "A mix")
    if not mix.components:
        raise ApprovalError("A mix needs at least one ingredient.")
    names = []
    for c in mix.components:
        p = db.get(fm.FeedProduct, c.feed_product_id)
        if p is None or p.farm_id != user.farm_id:
            raise ApprovalError("Ingredient not found", 404)
        names.append(p.name)
    if mix.feed_product_id:
        out = db.get(fm.FeedProduct, mix.feed_product_id)
        if out is None or out.farm_id != user.farm_id:
            raise ApprovalError("Feed not found", 404)
        output = out.name
    elif mix.new_product_name and mix.new_product_name.strip():
        output = mix.new_product_name.strip()
    else:
        raise ApprovalError("Say which feed the mix makes.")
    total = sum(c.actual_quantity for c in mix.components)
    summary = f"Mix of {output}: {total:g} {mix.unit} from {', '.join(names)}"
    return summary, mix.model_dump(mode="json")


def _check_milk(db: Session, user: models.User, target_id: str | None, payload: dict) -> tuple[str, dict, models.Animal]:
    if not target_id:
        raise ApprovalError("Name the milk record to correct.")
    record, animal = milk_service.get_record(db, target_id, user.farm_id)
    body = MilkCorrectionIn.model_validate({**payload, "reason": "-"})
    changes = body.model_dump(exclude={"reason"}, exclude_none=True)
    new, new_animal = milk_service.validate_correction(db, record, changes, user.farm_id)
    when = ensure_utc(record.recorded_at).date().isoformat()
    parts = []
    if new["liters"] != record.liters:
        parts.append(f"{record.liters:g} L → {float(new['liters']):g} L")
    if new["session"] != record.session:
        parts.append(f"{record.session} → {new['session']}")
    if new["destination"] != record.destination:
        parts.append(f"{record.destination} → {new['destination']}")
    if ensure_utc(new["recorded_at"]).date() != ensure_utc(record.recorded_at).date():
        parts.append(f"{when} → {ensure_utc(new['recorded_at']).date().isoformat()}")
    if new_animal.id != animal.id:
        parts.append(f"{animal.name} → {new_animal.name}")
    summary = f"Correct {animal.name}'s {record.session} milk of {when}: " + ", ".join(parts)
    return summary, body.model_dump(mode="json", exclude={"reason"}, exclude_none=True), animal


def _check_feeding(db: Session, user: models.User, target_id: str | None, payload: dict) -> tuple[str, dict, fm.FeedingEvent]:
    if not target_id:
        raise ApprovalError("Name the feeding to correct.")
    event = _feeding_event(db, target_id, user.farm_id)
    body = FeedingCorrectionIn.model_validate({**payload, "reason": "-"})
    subject = programs.load_subject(db, event.subject_type, event.subject_id, user.farm_id)
    for c in body.components:
        p = db.get(fm.FeedProduct, c.feed_product_id)
        if p is None or p.farm_id != user.farm_id:
            raise ApprovalError("Feed not found", 404)
    # Refused when asked, not when the manager approves (audit I-7).
    programs.check_consumption(db, [c.model_dump() for c in body.components])
    before = ", ".join(f"{c.quantity_offered:g} {c.unit}" for c in event.components) or "—"
    when = ensure_utc(event.occurred_at).date().isoformat()
    name = getattr(subject, "name", event.subject_id)
    if body.components:
        after = ", ".join(f"{c.quantity_offered:g} {c.unit or 'kg'}" for c in body.components)
        summary = f"Correct the feeding of {name} on {when}: {before} → {after}"
    else:
        summary = f"Undo the feeding of {name} on {when} ({before})"
    return summary, body.model_dump(mode="json", exclude={"reason"}), event


def _feeding_event(db: Session, event_id: str, farm_id: str) -> fm.FeedingEvent:
    event = db.get(fm.FeedingEvent, event_id)
    if event is None or event.farm_id != farm_id:
        raise ApprovalError("Feeding event not found", 404)
    if event.status != "recorded":
        raise ApprovalError("This feeding was already undone or corrected.", 409)
    return event


# ------------------------------------------------------------------ decide
def approve(db: Session, req: am.ApprovalRequest, user: models.User, *, note: str | None = None,
            allow_negative: bool = False, override_reason: str | None = None, confirm_duplicate: bool = False) -> am.ApprovalRequest:
    _ensure_decidable(db, req, user)
    if req.kind == "feed_mix":
        mix = QuickMixIn.model_validate(req.payload)
        override = allow_negative or mix.allow_negative
        ensure_stock_override(db, user, override, perms.FEED_NUTRITION)
        # The employee asked, the manager authorises the shortage: both are
        # named on the stock exception, with the manager's reason.
        stock_override = inv.Override(reason=_first_text(override_reason, mix.override_reason, note, req.reason), approved_by=user.id,
                                      requested_by=req.requested_by, approval_request_id=req.id) if override else None
        # The mix is the employee's work: they are its operator. Approving
        # it also approves the recipe a first mix of a feed creates.
        batch = batches.quick_mix(db, req.farm_id, feed_product_id=mix.feed_product_id, new_product_name=mix.new_product_name,
                                  components=[c.model_dump() for c in mix.components], output_quantity=mix.output_quantity, unit=mix.unit,
                                  produced_at=mix.produced_at, intended_species_code=mix.intended_species_code, notes=mix.notes,
                                  override=stock_override, can_approve=True, confirm_duplicate=confirm_duplicate or mix.confirm_duplicate,
                                  user_id=req.requested_by)
        perf.on_batch_completed(db, batch, user_id=user.id)
        req.result_type, req.result_id = "feed_batch", batch.id
    elif req.kind == "milk_correction":
        record, _ = milk_service.get_record(db, req.target_id, req.farm_id)
        record = milk_service.apply_correction(db, record, dict(req.payload), reason=req.reason or "", user=user,
                                               requested_by=req.requested_by, approval_request_id=req.id)
        req.result_type, req.result_id = "milk_record", record.id
    else:
        event = _feeding_event(db, req.target_id, req.farm_id)
        body = FeedingCorrectionIn.model_validate({**req.payload, "reason": req.reason or ""})
        result = correct_feeding(db, event, body, user=user, requested_by=req.requested_by, allow_negative=allow_negative or body.allow_negative,
                                 override_reason=_first_text(override_reason, body.override_reason, note, req.reason), approval_request_id=req.id)
        req.result_type, req.result_id = "feeding_event", result.id
    return _decided(db, req, user, "approved", note)


def reject(db: Session, req: am.ApprovalRequest, user: models.User, *, note: str | None) -> am.ApprovalRequest:
    _ensure_decidable(db, req, user)
    if not note or not note.strip():
        raise ApprovalError("Say why the request is rejected, so the employee knows.")
    return _decided(db, req, user, "rejected", note.strip())


def cancel(db: Session, req: am.ApprovalRequest, user: models.User) -> am.ApprovalRequest:
    if req.status != "pending":
        raise ApprovalError(f"This request is already {req.status}.", 409)
    if req.requested_by != user.id and not can_decide(db, user, req):
        raise ApprovalError("Only the person who asked can withdraw this request.", 403)
    req.status = "cancelled"
    req.decided_by, req.decided_at = user.id, now()
    write_event(db, farm_id=req.farm_id, entity_type="approval_request", entity_id=req.id, event_type="approval_request_cancelled",
                payload={"kind": req.kind, "summary": req.summary}, created_by=user.id)
    return req


def _ensure_decidable(db: Session, req: am.ApprovalRequest, user: models.User) -> None:
    if req.status != "pending":
        raise ApprovalError(f"This request is already {req.status}.", 409)
    if not can_decide(db, user, req):
        label = perms.MODULES_BY_CODE[req.module_code].label_en
        raise ApprovalError(f"Approving this needs {label} approval — the farm manager.", 403)


def _decided(db: Session, req: am.ApprovalRequest, user: models.User, decision: str, note: str | None) -> am.ApprovalRequest:
    req.status = decision
    req.decided_by, req.decided_at = user.id, now()
    req.decision_note = (note or "").strip() or None
    db.flush()
    write_event(db, farm_id=req.farm_id, entity_type="approval_request", entity_id=req.id, event_type=f"approval_request_{decision}",
                payload={"kind": req.kind, "summary": req.summary, "note": req.decision_note, "result_type": req.result_type, "result_id": req.result_id},
                created_by=user.id)
    requester = db.get(models.User, req.requested_by)
    if requester is not None and requester.id != user.id:
        verb = "approved" if decision == "approved" else "not approved"
        _notify(db, req, [requester], title=f"{user.name} {verb}: {req.summary}",
                description=req.decision_note or ("Recorded." if decision == "approved" else None), priority="medium")
    return req


# -------------------------------------------------------- feeding correction
def _first_text(*texts: str | None) -> str | None:
    return next((t.strip() for t in texts if t and t.strip()), None)


def correct_feeding(db: Session, event: fm.FeedingEvent, body: FeedingCorrectionIn, *, user: models.User, requested_by: str | None = None,
                    allow_negative: bool = False, override_reason: str | None = None, approval_request_id: str | None = None) -> fm.FeedingEvent:
    """Undoes [event] (its stock returns to its lots) and, when [body]
    names what was really fed, records that in its place — same subject,
    time and kind of feeding. Returns the replacement, or the reversal."""
    reason = (body.reason or "").strip()
    if not reason:
        raise ApprovalError("Say why the feeding is corrected.")
    programs.check_consumption(db, [c.model_dump() for c in body.components])  # audit I-7, before undoing anything
    ensure_stock_override(db, user, allow_negative, perms.FEED_NUTRITION)
    asked = db.get(models.User, requested_by) if requested_by else None
    reversal = programs.reverse_feeding(db, event, reason=reason + (f" (asked by {asked.name}, approved by {user.name})" if asked else ""), user_id=user.id)
    result = reversal
    if body.components:
        subject = programs.load_subject(db, event.subject_type, event.subject_id, event.farm_id)
        result = programs.record_feeding(db, event.farm_id, subject_type=event.subject_type, subject=subject,
                                         components=[c.model_dump() for c in body.components], event_type=event.event_type,
                                         occurred_at=event.occurred_at, head_count=event.head_count,
                                         notes=f"Correction of {event.id}: {reason}",
                                         override=inv.Override(reason=_first_text(override_reason, body.override_reason), approved_by=user.id,
                                                               requested_by=requested_by or user.id, approval_request_id=approval_request_id)
                                         if allow_negative else None,
                                         user_id=requested_by or user.id)
    write_event(db, farm_id=event.farm_id, entity_type=event.subject_type, entity_id=event.subject_id, event_type="feeding_corrected",
                payload={"feeding_event_id": event.id, "reversal_id": reversal.id, "replacement_id": result.id if result is not reversal else None,
                         "reason": reason, "requested_by": requested_by, "approval_request_id": approval_request_id}, created_by=user.id)
    return result


# ------------------------------------------------------------------- output
def _notify(db: Session, req: am.ApprovalRequest, people: list[models.User], *, title: str, description: str | None, priority: str = "high") -> None:
    for u in people:
        db.add(models.Notification(
            id=new_id(), farm_id=req.farm_id, user_id=u.id, module_code=req.module_code, notification_type="approval_request",
            title=title[:300], description=description, priority=priority, entity_type="approval_request", entity_id=req.id,
            source_type="approval_request", source_id=f"{req.id}|{u.id}", created_at=now(),
        ))


def to_dict(db: Session, req: am.ApprovalRequest) -> dict:
    asked = db.get(models.User, req.requested_by)
    decider = db.get(models.User, req.decided_by) if req.decided_by else None
    return {
        "id": req.id, "kind": req.kind, "module_code": req.module_code, "status": req.status, "summary": req.summary,
        "subject_type": req.subject_type, "subject_id": req.subject_id, "target_id": req.target_id, "payload": req.payload, "reason": req.reason,
        "requested_by": req.requested_by, "requested_by_name": asked.name if asked else None, "requested_at": ensure_utc(req.requested_at).isoformat(),
        "decided_by": req.decided_by, "decided_by_name": decider.name if decider else None,
        "decided_at": ensure_utc(req.decided_at).isoformat() if req.decided_at else None, "decision_note": req.decision_note,
        "result_type": req.result_type, "result_id": req.result_id,
    }
