from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import ensure_own_farm, owned_or_404, require_any_permission, require_farm_access, require_manager_role
from app.core import duplicates
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.repositories.base import new_id, write_event
from app.schemas.tasks import TaskCreate, TaskOut, TaskUpdate

router = APIRouter(prefix="/tasks", tags=["tasks"])

_TASKS_VIEW = require_farm_access(perms.TASKS)
_TASKS_CREATE = require_any_permission(perms.TASKS, action=perms.CREATE)
_TASKS_EDIT = require_any_permission(perms.TASKS, action=perms.EDIT)


@router.get("", response_model=list[TaskOut])
def list_tasks(
    status_filter: str | None = None, assigned_to: str | None = None, db: Session = Depends(get_db), user: models.User = Depends(_TASKS_VIEW)
) -> list[models.Task]:
    stmt = select(models.Task).where(models.Task.farm_id == user.farm_id)
    if status_filter:
        stmt = stmt.where(models.Task.status == status_filter)
    if assigned_to:
        stmt = stmt.where(models.Task.assigned_to == assigned_to)
    return list(db.scalars(stmt.order_by(models.Task.due_at)))


@router.post("", response_model=TaskOut, status_code=status.HTTP_201_CREATED)
def create_task(payload: TaskCreate, db: Session = Depends(get_db), current_user: models.User = Depends(_TASKS_CREATE)) -> models.Task:
    """"Farm managers decide, assign and review; employees see and act on
    their own tasks" — a task assigned to someone other than the creator
    requires a manager/owner; self-assigned tasks (a worker jotting down
    their own reminder) need no special role.
    """
    ensure_own_farm(current_user, payload.farm_id)
    if payload.assigned_to and payload.assigned_to != current_user.id and current_user.role not in ("owner", "manager"):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only a farm manager or owner can assign a task to someone else.")
    if payload.assigned_to:
        owned_or_404(db, models.User, payload.assigned_to, current_user, "Assignee")
    # The same job written down twice (two people, or one person twice).
    # Tasks the system raised itself (source_type) are de-duplicated there.
    twin = None
    if payload.source_type is None:
        twin = db.scalar(select(models.Task).where(
            models.Task.farm_id == payload.farm_id, func.lower(models.Task.title) == payload.title.lower(),
            models.Task.status.notin_(("done", "completed", "cancelled")),
            models.Task.assigned_to.is_(None) if payload.assigned_to is None else models.Task.assigned_to == payload.assigned_to,
        ))
    duplicates.guard(twin, f"the task \"{payload.title}\" is already open.", confirm=payload.confirm_duplicate)
    task = models.Task(id=new_id(), **payload.model_dump(exclude={"confirm_duplicate"}))
    db.add(task)
    write_event(
        db,
        farm_id=payload.farm_id,
        entity_type="task",
        entity_id=task.id,
        event_type="task_created",
        payload={"title": payload.title, "source_type": payload.source_type, "assigned_to": payload.assigned_to},
        created_by=current_user.id,
    )
    db.commit()
    db.refresh(task)
    return task


@router.patch("/{task_id}", response_model=TaskOut)
def update_task(
    task_id: str, payload: TaskUpdate, db: Session = Depends(get_db), current_user: models.User = Depends(_TASKS_EDIT)
) -> models.Task:
    task = owned_or_404(db, models.Task, task_id, current_user, "Task")

    changes = payload.model_dump(exclude_unset=True)
    is_manager = current_user.role in ("owner", "manager")
    if "assigned_to" in changes and changes["assigned_to"] != current_user.id and not is_manager:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only a farm manager or owner can reassign a task.")
    if changes.get("assigned_to"):
        owned_or_404(db, models.User, changes["assigned_to"], current_user, "Assignee")
    if not is_manager and task.assigned_to not in (None, current_user.id):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "You can only update a task assigned to you.")

    for field, value in changes.items():
        setattr(task, field, value)
    write_event(
        db,
        farm_id=task.farm_id,
        entity_type="task",
        entity_id=task.id,
        event_type="task_updated",
        payload=changes,
        created_by=current_user.id,
    )
    db.commit()
    db.refresh(task)
    return task


@router.delete("/{task_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_task(task_id: str, db: Session = Depends(get_db), current_user: models.User = Depends(require_manager_role)) -> None:
    task = owned_or_404(db, models.Task, task_id, current_user, "Task")
    write_event(db, farm_id=task.farm_id, entity_type="task", entity_id=task.id, event_type="task_deleted", payload={"title": task.title}, created_by=current_user.id)
    db.delete(task)
    db.commit()
