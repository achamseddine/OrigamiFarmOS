from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.api.deps import require_farm_access
from app.core import permissions as perms
from app.db.base import get_db
from app.domain import models
from app.schemas.sales import CustomerOut, ExpenseOut, SaleOut, SupplierOut

router = APIRouter(tags=["sales"])

# Finance is the tablet's Sales & Finance screen, which shows all of these;
# Sales and Expenses are the narrower responsibilities a manager can grant.
_SALES_VIEW = require_farm_access(perms.SALES, perms.FINANCE)
_EXPENSES_VIEW = require_farm_access(perms.EXPENSES, perms.FINANCE)
# Suppliers are named on stock receipts and on expenses.
_SUPPLIERS_VIEW = require_farm_access(perms.INVENTORY, perms.FEED_NUTRITION, perms.EXPENSES, perms.FINANCE)


@router.get("/sales", response_model=list[SaleOut])
def list_sales(db: Session = Depends(get_db), user: models.User = Depends(_SALES_VIEW)) -> list[models.Sale]:
    """Read-only for now — every row here today comes from the Mouneh and
    Visits modules' own sale-recording endpoints (`product_type` is
    'mouneh'/'visitor_retail'); a general manual sale-entry endpoint is
    tracked as follow-on work, not yet built.
    """
    return list(db.scalars(select(models.Sale).where(models.Sale.farm_id == user.farm_id).order_by(models.Sale.sold_at.desc())))


@router.get("/expenses", response_model=list[ExpenseOut])
def list_expenses(db: Session = Depends(get_db), user: models.User = Depends(_EXPENSES_VIEW)) -> list[models.Expense]:
    return list(db.scalars(select(models.Expense).where(models.Expense.farm_id == user.farm_id).order_by(models.Expense.incurred_at.desc())))


@router.get("/customers", response_model=list[CustomerOut])
def list_customers(db: Session = Depends(get_db), user: models.User = Depends(_SALES_VIEW)) -> list[models.Customer]:
    return list(db.scalars(select(models.Customer).where(models.Customer.farm_id == user.farm_id).order_by(models.Customer.name)))


@router.get("/suppliers", response_model=list[SupplierOut])
def list_suppliers(db: Session = Depends(get_db), user: models.User = Depends(_SUPPLIERS_VIEW)) -> list[models.Supplier]:
    return list(db.scalars(select(models.Supplier).where(models.Supplier.farm_id == user.farm_id).order_by(models.Supplier.name)))
