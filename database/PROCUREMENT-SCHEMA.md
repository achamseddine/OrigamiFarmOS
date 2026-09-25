# Database Pass 5A — Supplier, Procurement & Purchasing

**Status:** Canonical implementation baseline  
**Depends on:** Foundation, Inventory  
**Integrates with:** Feed, Health, Assets, Crops, Finance/Costing

## 1. Boundary
Procurement owns sourcing, requisition, approval, ordering and commercial receipt matching. Inventory owns physical stock truth. Finance owns accounting/payment truth. A PO is not stock; a receipt is not an invoice; an approved requisition is not a purchase.

## 2. supplier
```sql
supplier (
 id uuid primary key,
 organization_id uuid not null references organization(id),
 code varchar(80) not null,
 legal_name varchar(250) not null,
 display_name varchar(200),
 tax_registration_no varchar(100),
 status varchar(30) not null,
 default_currency char(3),
 payment_terms_code varchar(50),
 lead_time_days numeric(10,2),
 created_at timestamptz not null,
 updated_at timestamptz not null,
 unique (organization_id, code)
)
```

## 3. supplier_contact / address
```sql
supplier_contact (
 id uuid primary key,
 supplier_id uuid not null references supplier(id),
 contact_type varchar(40) not null,
 name varchar(150),
 value varchar(320) not null,
 is_primary boolean not null default false,
 active boolean not null default true
)

supplier_address (
 id uuid primary key,
 supplier_id uuid not null references supplier(id),
 address_type varchar(40) not null,
 line1 varchar(200),
 line2 varchar(200),
 city varchar(120),
 region varchar(120),
 country_code char(2),
 postal_code varchar(30),
 active boolean not null default true
)
```

## 4. supplier_item
Links supplier commercial catalog to canonical inventory items.
```sql
supplier_item (
 id uuid primary key,
 supplier_id uuid not null references supplier(id),
 inventory_item_id uuid not null references inventory_item(id),
 supplier_item_code varchar(120),
 description varchar(250),
 purchase_uom_id uuid not null references uom(id),
 pack_quantity numeric(20,6),
 minimum_order_quantity numeric(20,6),
 standard_lead_time_days numeric(10,2),
 status varchar(30) not null,
 unique (supplier_id, inventory_item_id, supplier_item_code)
)
```
Supplier description/code never replaces internal item identity.

## 5. purchase_requisition
```sql
purchase_requisition (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 requisition_no varchar(80) not null,
 requested_by uuid not null references user_account(id),
 requested_at timestamptz not null,
 needed_by date,
 purpose_code varchar(60),
 status varchar(30) not null,
 justification text,
 source_type varchar(60),
 source_reference_id uuid,
 total_estimated_amount numeric(20,4),
 currency char(3),
 created_at timestamptz not null,
 unique (farm_id, requisition_no)
)

purchase_requisition_line (
 id uuid primary key,
 requisition_id uuid not null references purchase_requisition(id),
 line_no integer not null,
 inventory_item_id uuid not null references inventory_item(id),
 requested_quantity numeric(20,6) not null,
 uom_id uuid not null references uom(id),
 estimated_unit_price numeric(20,6),
 preferred_supplier_id uuid references supplier(id),
 specification text,
 status varchar(30) not null,
 source_recommendation_id uuid,
 unique (requisition_id,line_no),
 check (requested_quantity > 0)
)
```
Feed replenishment can propose/draft a requisition but cannot approve it.

## 6. procurement_approval
```sql
procurement_approval (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 document_type varchar(40) not null,
 document_id uuid not null,
 approval_stage varchar(60) not null,
 decision varchar(30) not null,
 decided_by uuid not null references user_account(id),
 decided_at timestamptz not null,
 authority_snapshot jsonb not null,
 comments text
)
```
Approval authority is evaluated at decision time and snapshot for audit. Approval does not mutate history if delegation later changes.

## 7. purchase_order
```sql
purchase_order (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 supplier_id uuid not null references supplier(id),
 po_no varchar(80) not null,
 order_date date not null,
 expected_delivery_date date,
 currency char(3) not null,
 status varchar(30) not null,
 payment_terms_code varchar(50),
 subtotal numeric(20,4),
 discount_amount numeric(20,4),
 tax_amount numeric(20,4),
 freight_amount numeric(20,4),
 total_amount numeric(20,4),
 created_by uuid references user_account(id),
 approved_by uuid references user_account(id),
 approved_at timestamptz,
 created_at timestamptz not null,
 unique (farm_id,po_no)
)

purchase_order_line (
 id uuid primary key,
 purchase_order_id uuid not null references purchase_order(id),
 requisition_line_id uuid references purchase_requisition_line(id),
 line_no integer not null,
 inventory_item_id uuid not null references inventory_item(id),
 ordered_quantity numeric(20,6) not null,
 purchase_uom_id uuid not null references uom(id),
 base_quantity numeric(20,6) not null,
 unit_price numeric(20,6) not null,
 discount_amount numeric(20,4) not null default 0,
 tax_amount numeric(20,4) not null default 0,
 line_total numeric(20,4) not null,
 status varchar(30) not null,
 unique (purchase_order_id,line_no),
 check (ordered_quantity > 0),
 check (base_quantity > 0)
)
```
The purchase-UOM to item-base-UOM conversion used by the order is snapshotted so later UOM configuration changes cannot alter historical quantities.

## 8. goods_receipt
```sql
goods_receipt (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 supplier_id uuid not null references supplier(id),
 purchase_order_id uuid references purchase_order(id),
 receipt_no varchar(80) not null,
 received_at timestamptz not null,
 received_by uuid references user_account(id),
 delivery_note_no varchar(120),
 status varchar(30) not null,
 created_at timestamptz not null,
 unique (farm_id,receipt_no)
)

goods_receipt_line (
 id uuid primary key,
 goods_receipt_id uuid not null references goods_receipt(id),
 purchase_order_line_id uuid references purchase_order_line(id),
 line_no integer not null,
 inventory_item_id uuid not null references inventory_item(id),
 received_quantity numeric(20,6) not null,
 accepted_quantity numeric(20,6) not null,
 rejected_quantity numeric(20,6) not null default 0,
 uom_id uuid not null references uom(id),
 base_accepted_quantity numeric(20,6) not null,
 inventory_lot_id uuid references inventory_lot(id),
 inventory_receipt_transaction_id uuid references inventory_transaction(id),
 rejection_reason varchar(200),
 unique (goods_receipt_id,line_no),
 check (received_quantity >= 0),
 check (accepted_quantity >= 0),
 check (rejected_quantity >= 0),
 check (accepted_quantity + rejected_quantity <= received_quantity)
)
```
Posting accepted quantity creates/links inventory lot and RECEIPT ledger transaction atomically. Rejected quantity does not inflate stock.

## 9. supplier_return
```sql
supplier_return (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 supplier_id uuid not null references supplier(id),
 goods_receipt_id uuid references goods_receipt(id),
 return_no varchar(80) not null,
 returned_at timestamptz not null,
 reason_code varchar(60),
 status varchar(30) not null,
 unique (farm_id,return_no)
)

supplier_return_line (
 id uuid primary key,
 supplier_return_id uuid not null references supplier_return(id),
 inventory_lot_id uuid not null references inventory_lot(id),
 quantity_base numeric(20,6) not null,
 inventory_return_transaction_id uuid references inventory_transaction(id),
 check (quantity_base > 0)
)
```

## 10. supplier performance
Supplier performance is derived from facts: requested/ordered/received dates, accepted/rejected quantities, quality outcomes and commercial records. Do not store subjective supplier score as immutable truth without methodology/version.

## 11. Events
PurchaseRequisitionCreated, PurchaseRequisitionApproved, PurchaseRequisitionRejected, PurchaseOrderCreated, PurchaseOrderApproved, PurchaseOrderSent, GoodsReceived, GoodsRejected, SupplierReturnPosted, PurchaseOrderClosed.

## 12. Acceptance
The system distinguishes requested/approved/ordered/received/accepted/stocked quantities; partial deliveries work; feed alerts can initiate drafts but not approve purchases; accepted goods become inventory atomically; supplier item codes never replace internal item identity; procurement history survives price/UOM/config changes.
