from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, require_manager_role
from app.db.base import get_db
from app.domain import models
from app.repositories.base import new_id, write_event
from app.schemas.tasks import TaskCreate, TaskOut, TaskUpdate

router = APIRouter(prefix="/tasks", tags=["tasks"])


@router.get("", response_model=list[TaskOut])
def list_tasks(
    farm_id: str, status_filter: str | None = None, assigned_to: str | None = None, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)
) -> list[models.Task]:
    stmt = select(models.Task).where(models.Task.farm_id == farm_id)
    if status_filter:
        stmt = stmt.where(models.Task.status == status_filter)
    if assigned_to:
        stmt = stmt.where(models.Task.assigned_to == assigned_to)
    return list(db.scalars(stmt.order_by(models.Task.due_at)))


@router.post("", response_model=TaskOut, status_code=status.HTTP_201_CREATED)
def create_task(payload: TaskCreate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)) -> models.Task:
    """"Farm managers decide, assign and review; employees see and act on
    their own tasks" — a task assigned to someone other than the creator
    requires a manager/owner; self-assigned tasks (a worker jotting down
    their own reminder) need no special role.
    """
    if payload.assigned_to and payload.assigned_to != current_user.id and current_user.role not in ("owner", "manager"):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only a farm manager or owner can assign a task to someone else.")
    task = models.Task(id=new_id(), **payload.model_dump())
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
    task_id: str, payload: TaskUpdate, db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)
) -> models.Task:
    task = db.get(models.Task, task_id)
    if task is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Task not found")

    changes = payload.model_dump(exclude_unset=True)
    is_manager = current_user.role in ("owner", "manager")
    if "assigned_to" in changes and changes["assigned_to"] != current_user.id and not is_manager:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only a farm manager or owner can reassign a task.")
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
    task = db.get(models.Task, task_id)
    if task is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Task not found")
    write_event(db, farm_id=task.farm_id, entity_type="task", entity_id=task.id, event_type="task_deleted", payload={"title": task.title}, created_by=current_user.id)
    db.delete(task)
    db.commit()
