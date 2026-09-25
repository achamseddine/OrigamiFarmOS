# Database Pass 7B — Invoicing, Receivables, Cash & Payments

**Status:** Farm operational finance baseline  
**Important:** This does not claim to be a full statutory accounting/general-ledger system.

## 1. sales_invoice
```sql
sales_invoice (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 customer_id uuid not null references customer(id),
 invoice_no varchar(80) not null,
 invoice_date date not null,
 due_date date,
 currency char(3) not null,
 status varchar(30) not null,
 subtotal numeric(20,4) not null,
 discount_amount numeric(20,4) not null default 0,
 tax_amount numeric(20,4) not null default 0,
 total_amount numeric(20,4) not null,
 outstanding_amount numeric(20,4) not null,
 created_at timestamptz not null,
 posted_at timestamptz,
 unique (farm_id,invoice_no)
)

sales_invoice_line (
 id uuid primary key,
 sales_invoice_id uuid not null references sales_invoice(id),
 line_no integer not null,
 sales_order_line_id uuid references sales_order_line(id),
 delivery_line_id uuid references delivery_line(id),
 saleable_product_id uuid not null references saleable_product(id),
 quantity numeric(20,6) not null,
 uom_id uuid not null references uom(id),
 unit_price numeric(20,6) not null,
 discount_amount numeric(20,4) not null default 0,
 tax_amount numeric(20,4) not null default 0,
 line_total numeric(20,4) not null,
 unique (sales_invoice_id,line_no)
)
```
Outstanding may be a controlled projection/cache derived from posted invoice, credit notes and allocations; source payment/allocation facts remain authoritative.

## 2. credit_note
```sql
credit_note (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 customer_id uuid not null references customer(id),
 sales_invoice_id uuid references sales_invoice(id),
 credit_note_no varchar(80) not null,
 credit_date date not null,
 currency char(3) not null,
 amount numeric(20,4) not null,
 reason_code varchar(60),
 status varchar(30) not null,
 posted_at timestamptz,
 unique (farm_id,credit_note_no),
 check (amount > 0)
)
```

## 3. financial_account
Operational money container.
```sql
financial_account (
 id uuid primary key,
 organization_id uuid not null references organization(id),
 code varchar(80) not null,
 name varchar(150) not null,
 account_type varchar(30) not null,
 currency char(3) not null,
 status varchar(30) not null,
 unique (organization_id,code)
)
```
Types: CASH, BANK, MOBILE_MONEY, CLEARING. This is not the statutory chart of accounts.

## 4. payment
```sql
payment (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 customer_id uuid references customer(id),
 supplier_id uuid references supplier(id),
 payment_direction varchar(20) not null,
 financial_account_id uuid not null references financial_account(id),
 payment_date date not null,
 amount numeric(20,4) not null,
 currency char(3) not null,
 payment_method varchar(40) not null,
 reference_no varchar(120),
 status varchar(30) not null,
 reversal_of_id uuid references payment(id),
 recorded_by uuid references user_account(id),
 recorded_at timestamptz not null,
 check (amount > 0),
 check (num_nonnulls(customer_id,supplier_id) <= 1)
)
```
Direction: RECEIPT or PAYMENT.

## 5. payment_allocation
```sql
payment_allocation (
 id uuid primary key,
 payment_id uuid not null references payment(id),
 sales_invoice_id uuid references sales_invoice(id),
 supplier_document_type varchar(40),
 supplier_document_id uuid,
 allocated_amount numeric(20,4) not null,
 allocation_date date not null,
 check (allocated_amount > 0),
 check (sales_invoice_id is not null or supplier_document_id is not null)
)
```
Supports partial payment and one payment across multiple invoices. Supplier-side invoice schema may be introduced later/through accounting integration.

## 6. cash_transaction
For farm cash movements not represented by customer/supplier payment.
```sql
cash_transaction (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 financial_account_id uuid not null references financial_account(id),
 transaction_type varchar(40) not null,
 occurred_at timestamptz not null,
 amount numeric(20,4) not null,
 currency char(3) not null,
 category_code varchar(60),
 source_type varchar(80),
 source_id uuid,
 description text,
 reversal_of_id uuid references cash_transaction(id),
 recorded_by uuid references user_account(id),
 recorded_at timestamptz not null,
 check (amount > 0)
)
```

## 7. AR aging projection
Rebuildable projection:
- current/not due;
- 1–30 overdue;
- 31–60;
- 61–90;
- >90;
- total outstanding.
Aging uses posted invoice/credit/payment allocations and report-as-of date.

## 8. Multi-currency
Original amount/currency are immutable. Base-currency analytics store/derive FX rate, source and conversion date. Never replace transaction currency with current FX.

## 9. Events
SalesInvoicePosted, CreditNotePosted, CustomerPaymentReceived, PaymentAllocated, PaymentReversed, CashTransactionRecorded, InvoiceOverdue.

## 10. Acceptance
Partial payments and allocations work; customer balance is reconstructable; cash/bank balances derive from posted money movements; sales/production quantities are not altered by invoicing; operational finance remains clearly separate from statutory accounting.
