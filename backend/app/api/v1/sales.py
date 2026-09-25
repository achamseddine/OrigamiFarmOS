from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.base import get_db
from app.domain import models
from app.schemas.sales import CustomerOut, ExpenseOut, SaleOut, SupplierOut

router = APIRouter(tags=["sales"])


@router.get("/sales", response_model=list[SaleOut])
def list_sales(farm_id: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> list[models.Sale]:
    """Read-only for now — every row here today comes from the Mouneh and
    Visits modules' own sale-recording endpoints (`product_type` is
    'mouneh'/'visitor_retail'); a general manual sale-entry endpoint is
    tracked as follow-on work, not yet built.
    """
    return list(db.scalars(select(models.Sale).where(models.Sale.farm_id == farm_id).order_by(models.Sale.sold_at.desc())))


@router.get("/expenses", response_model=list[ExpenseOut])
def list_expenses(farm_id: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> list[models.Expense]:
    return list(db.scalars(select(models.Expense).where(models.Expense.farm_id == farm_id).order_by(models.Expense.incurred_at.desc())))


@router.get("/customers", response_model=list[CustomerOut])
def list_customers(farm_id: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> list[models.Customer]:
    return list(db.scalars(select(models.Customer).where(models.Customer.farm_id == farm_id).order_by(models.Customer.name)))


@router.get("/suppliers", response_model=list[SupplierOut])
def list_suppliers(farm_id: str, db: Session = Depends(get_db), _user: models.User = Depends(get_current_user)) -> list[models.Supplier]:
    return list(db.scalars(select(models.Supplier).where(models.Supplier.farm_id == farm_id).order_by(models.Supplier.name)))
