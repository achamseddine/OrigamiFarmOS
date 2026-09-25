# Database Pass 7A — Customers, Sales Orders, Delivery & Returns

**Status:** Canonical implementation baseline  
**Depends on:** Foundation, Inventory, Production, Costing  
**Integrates with:** Livestock, Crops, Finance

## 1. Boundary
Sales owns customer demand, pricing, commercial commitment, delivery and return. Inventory owns stock. Production owns what was produced. Finance owns receivables/payment. A sales order is not revenue/cash and does not reduce stock.

## 2. customer
```sql
customer (
 id uuid primary key,
 organization_id uuid not null references organization(id),
 code varchar(80) not null,
 legal_name varchar(250) not null,
 display_name varchar(200),
 customer_type varchar(50) not null,
 tax_registration_no varchar(100),
 default_currency char(3),
 payment_terms_code varchar(50),
 credit_limit numeric(20,4),
 status varchar(30) not null,
 created_at timestamptz not null,
 updated_at timestamptz not null,
 unique (organization_id,code)
)
```

## 3. customer_contact / address
```sql
customer_contact (
 id uuid primary key,
 customer_id uuid not null references customer(id),
 contact_type varchar(40) not null,
 name varchar(150),
 value varchar(320) not null,
 is_primary boolean not null default false,
 active boolean not null default true
)

customer_address (
 id uuid primary key,
 customer_id uuid not null references customer(id),
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

## 4. saleable_product
Commercial product mapped to canonical inventory/production where applicable.
```sql
saleable_product (
 id uuid primary key,
 organization_id uuid not null references organization(id),
 code varchar(80) not null,
 name varchar(180) not null,
 product_type varchar(50) not null,
 inventory_item_id uuid references inventory_item(id),
 default_sales_uom_id uuid not null references uom(id),
 status varchar(30) not null,
 unique (organization_id,code)
)
```
Types include MILK, EGGS, WOOL, CROP, FEED, ANIMAL, OTHER. Saleable product is commercial semantics, not a second stock master.

## 5. price_list
```sql
price_list (
 id uuid primary key,
 organization_id uuid not null references organization(id),
 code varchar(80) not null,
 name varchar(150) not null,
 currency char(3) not null,
 valid_from date,
 valid_to date,
 status varchar(30) not null,
 unique (organization_id,code)
)

price_list_line (
 id uuid primary key,
 price_list_id uuid not null references price_list(id),
 saleable_product_id uuid not null references saleable_product(id),
 unit_price numeric(20,6) not null,
 sales_uom_id uuid not null references uom(id),
 minimum_quantity numeric(20,6),
 valid_from date,
 valid_to date
)
```
Order lines snapshot agreed price; later price-list changes do not rewrite history.

## 6. sales_order
```sql
sales_order (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 customer_id uuid not null references customer(id),
 order_no varchar(80) not null,
 order_date date not null,
 requested_delivery_date date,
 currency char(3) not null,
 status varchar(30) not null,
 payment_terms_code varchar(50),
 subtotal numeric(20,4),
 discount_amount numeric(20,4),
 tax_amount numeric(20,4),
 total_amount numeric(20,4),
 created_by uuid references user_account(id),
 approved_by uuid references user_account(id),
 approved_at timestamptz,
 created_at timestamptz not null,
 unique (farm_id,order_no)
)

sales_order_line (
 id uuid primary key,
 sales_order_id uuid not null references sales_order(id),
 line_no integer not null,
 saleable_product_id uuid not null references saleable_product(id),
 inventory_item_id uuid references inventory_item(id),
 ordered_quantity numeric(20,6) not null,
 sales_uom_id uuid not null references uom(id),
 base_quantity numeric(20,6),
 unit_price numeric(20,6) not null,
 discount_amount numeric(20,4) not null default 0,
 tax_amount numeric(20,4) not null default 0,
 line_total numeric(20,4) not null,
 status varchar(30) not null,
 unique (sales_order_id,line_no),
 check (ordered_quantity > 0)
)
```

## 7. delivery
```sql
delivery (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 customer_id uuid not null references customer(id),
 sales_order_id uuid references sales_order(id),
 delivery_no varchar(80) not null,
 delivered_at timestamptz,
 status varchar(30) not null,
 destination_address_id uuid references customer_address(id),
 delivered_by uuid references user_account(id),
 created_at timestamptz not null,
 unique (farm_id,delivery_no)
)

delivery_line (
 id uuid primary key,
 delivery_id uuid not null references delivery(id),
 sales_order_line_id uuid references sales_order_line(id),
 line_no integer not null,
 inventory_item_id uuid references inventory_item(id),
 inventory_lot_id uuid references inventory_lot(id),
 animal_id uuid references animal(id),
 delivered_quantity numeric(20,6) not null,
 uom_id uuid not null references uom(id),
 inventory_issue_transaction_id uuid references inventory_transaction(id),
 unique (delivery_id,line_no),
 check (delivered_quantity > 0)
)
```
For stock products, posting delivery creates inventory ISSUE/RETURN_OUT as configured. For live-animal sale, controlled livestock disposition/ownership workflow applies; do not treat the animal as a consumable inventory row.

## 8. sales_return
```sql
sales_return (
 id uuid primary key,
 farm_id uuid not null references farm(id),
 customer_id uuid not null references customer(id),
 delivery_id uuid references delivery(id),
 return_no varchar(80) not null,
 returned_at timestamptz not null,
 reason_code varchar(60),
 status varchar(30) not null,
 unique (farm_id,return_no)
)

sales_return_line (
 id uuid primary key,
 sales_return_id uuid not null references sales_return(id),
 delivery_line_id uuid references delivery_line(id),
 inventory_item_id uuid references inventory_item(id),
 inventory_lot_id uuid references inventory_lot(id),
 quantity numeric(20,6) not null,
 uom_id uuid not null references uom(id),
 inventory_return_transaction_id uuid references inventory_transaction(id),
 quality_disposition varchar(40),
 check (quantity > 0)
)
```
Returned food/feed is not automatically saleable inventory; quality disposition controls quarantine/release.

## 9. Production linkage
Milk/eggs/crops can be produced in one or more production/harvest records and pooled into inventory lots before sale. Sales never changes production facts.

## 10. Events
CustomerCreated, SalesOrderCreated, SalesOrderApproved, DeliveryPosted, ProductDelivered, SalesReturnPosted, SalesOrderClosed, AnimalSaleCompleted.

## 11. Acceptance
Orders do not reduce stock; partial deliveries work; delivered lots remain traceable to production/harvest/feed inputs; live-animal sale uses livestock disposition; returns preserve genealogy and quality state; price history remains stable.
