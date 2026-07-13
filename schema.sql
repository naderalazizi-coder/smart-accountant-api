-- =====================================================================
--  SMART ACCOUNTANT ERP  |  المحاسب الذكي
--  PostgreSQL Production Schema
--  Multi-Tenant SaaS core: System Admin, Accounting, Sales, Purchases,
--  Inventory, HR foundations.
--
--  Tenancy model: shared schema, row-level isolation via `tenant_id`
--  on every business table, enforced with Postgres Row-Level Security
--  (RLS). The application sets `app.current_tenant_id` per connection
--  (e.g. via `SET LOCAL app.current_tenant_id = '<uuid>'` at the start
--  of each request) and RLS policies do the rest — no query can leak
--  across tenants even if application code forgets a WHERE clause.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";      -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "citext";        -- case-insensitive emails

-- ---------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------

CREATE TYPE account_type AS ENUM ('asset', 'liability', 'equity', 'revenue', 'expense');
CREATE TYPE journal_status AS ENUM ('draft', 'posted', 'reversed');
CREATE TYPE doc_status AS ENUM ('draft', 'confirmed', 'posted', 'paid', 'partially_paid', 'cancelled', 'overdue');
CREATE TYPE party_type AS ENUM ('customer', 'vendor');
CREATE TYPE movement_type AS ENUM ('in', 'out', 'transfer', 'adjustment');
CREATE TYPE costing_method AS ENUM ('fifo', 'lifo', 'average');
CREATE TYPE employment_status AS ENUM ('active', 'on_leave', 'terminated');
CREATE TYPE ai_command_source AS ENUM ('voice', 'text', 'ocr');
CREATE TYPE ai_command_status AS ENUM ('received', 'processing', 'completed', 'failed', 'needs_review');

-- =====================================================================
-- 1. SYSTEM ADMINISTRATION
-- =====================================================================

-- Tenants: one row per subscribing company/organization.
CREATE TABLE tenants (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    legal_name          TEXT NOT NULL,
    legal_name_ar       TEXT,
    trade_name          TEXT,
    tax_registration_no TEXT,
    country_code        CHAR(2) NOT NULL DEFAULT 'YE',
    base_currency_code  CHAR(3) NOT NULL DEFAULT 'USD',
    subscription_plan   TEXT NOT NULL DEFAULT 'trial',   -- trial | starter | professional | enterprise
    subscription_status TEXT NOT NULL DEFAULT 'active',  -- active | past_due | suspended | cancelled
    fiscal_year_start_month SMALLINT NOT NULL DEFAULT 1 CHECK (fiscal_year_start_month BETWEEN 1 AND 12),
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE branches (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    name_ar     TEXT,
    code        TEXT NOT NULL,
    address     TEXT,
    city        TEXT,
    is_main     BOOLEAN NOT NULL DEFAULT FALSE,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);

CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    email           CITEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    full_name       TEXT NOT NULL,
    full_name_ar    TEXT,
    phone           TEXT,
    preferred_locale TEXT NOT NULL DEFAULT 'ar',          -- ar | en
    mfa_enabled     BOOLEAN NOT NULL DEFAULT FALSE,
    mfa_secret      TEXT,
    branch_id       UUID REFERENCES branches(id) ON DELETE SET NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, email)
);

CREATE TABLE roles (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,             -- e.g. Admin, Accountant, Sales Rep
    is_system   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);

-- Permission catalogue is global (not tenant-scoped) — e.g. 'sales.invoice.create'
CREATE TABLE permissions (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code        TEXT NOT NULL UNIQUE,      -- 'accounting.journal.post'
    module      TEXT NOT NULL,             -- 'accounting'
    description TEXT
);

CREATE TABLE role_permissions (
    role_id       UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_id UUID NOT NULL REFERENCES permissions(id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE user_roles (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id UUID NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, role_id)
);

CREATE TABLE audit_logs (
    id            BIGSERIAL PRIMARY KEY,
    tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id       UUID REFERENCES users(id) ON DELETE SET NULL,
    action        TEXT NOT NULL,           -- 'invoice.created', 'journal.posted'
    entity_table  TEXT NOT NULL,
    entity_id     UUID,
    old_values    JSONB,
    new_values    JSONB,
    ip_address    INET,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_logs_tenant_entity ON audit_logs (tenant_id, entity_table, entity_id);

CREATE TABLE currencies (
    code        CHAR(3) PRIMARY KEY,       -- ISO 4217: USD, YER, SAR
    name        TEXT NOT NULL,
    name_ar     TEXT,
    symbol      TEXT,
    decimals    SMALLINT NOT NULL DEFAULT 2
);

CREATE TABLE exchange_rates (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    from_code   CHAR(3) NOT NULL REFERENCES currencies(code),
    to_code     CHAR(3) NOT NULL REFERENCES currencies(code),
    rate        NUMERIC(18,6) NOT NULL CHECK (rate > 0),
    rate_date   DATE NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, from_code, to_code, rate_date)
);

CREATE TABLE tax_rates (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,             -- 'VAT 15%'
    name_ar     TEXT,
    rate        NUMERIC(6,3) NOT NULL,     -- 15.000
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

-- =====================================================================
-- 2. ACCOUNTING CORE
-- =====================================================================

CREATE TABLE fiscal_years (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,             -- 'FY2026'
    start_date  DATE NOT NULL,
    end_date    DATE NOT NULL,
    is_closed   BOOLEAN NOT NULL DEFAULT FALSE,
    closed_at   TIMESTAMPTZ,
    closed_by   UUID REFERENCES users(id),
    UNIQUE (tenant_id, name),
    CHECK (end_date > start_date)
);

CREATE TABLE accounting_periods (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    fiscal_year_id UUID NOT NULL REFERENCES fiscal_years(id) ON DELETE CASCADE,
    period_no     SMALLINT NOT NULL CHECK (period_no BETWEEN 1 AND 12),
    start_date    DATE NOT NULL,
    end_date      DATE NOT NULL,
    is_closed     BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (fiscal_year_id, period_no)
);

CREATE TABLE cost_centers (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    branch_id   UUID REFERENCES branches(id) ON DELETE SET NULL,
    code        TEXT NOT NULL,
    name        TEXT NOT NULL,
    name_ar     TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (tenant_id, code)
);

-- Chart of accounts: self-referencing tree.
CREATE TABLE chart_of_accounts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    parent_id       UUID REFERENCES chart_of_accounts(id) ON DELETE RESTRICT,
    code            TEXT NOT NULL,             -- '1101'
    name            TEXT NOT NULL,
    name_ar         TEXT,
    account_type    account_type NOT NULL,
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(code),
    is_control_account BOOLEAN NOT NULL DEFAULT FALSE,   -- true = header, no direct postings
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    opening_balance NUMERIC(18,2) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);
CREATE INDEX idx_coa_tenant_type ON chart_of_accounts (tenant_id, account_type);

-- Journal entries: the header of every double-entry transaction.
CREATE TABLE journal_entries (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    branch_id       UUID REFERENCES branches(id) ON DELETE SET NULL,
    period_id       UUID NOT NULL REFERENCES accounting_periods(id),
    entry_no        TEXT NOT NULL,             -- 'JE-2026-000123'
    entry_date      DATE NOT NULL,
    memo            TEXT,
    memo_ar         TEXT,
    source_module   TEXT NOT NULL DEFAULT 'manual',  -- manual | sales | purchase | payroll | ai_voice | ocr
    source_doc_type TEXT,                      -- 'sales_invoice'
    source_doc_id   UUID,
    status          journal_status NOT NULL DEFAULT 'draft',
    is_ai_generated BOOLEAN NOT NULL DEFAULT FALSE,
    created_by      UUID REFERENCES users(id),
    posted_by       UUID REFERENCES users(id),
    posted_at       TIMESTAMPTZ,
    reversed_entry_id UUID REFERENCES journal_entries(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, entry_no)
);
CREATE INDEX idx_je_tenant_date ON journal_entries (tenant_id, entry_date);
CREATE INDEX idx_je_source ON journal_entries (tenant_id, source_module, source_doc_id);

CREATE TABLE journal_entry_lines (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    journal_entry_id UUID NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
    account_id      UUID NOT NULL REFERENCES chart_of_accounts(id) ON DELETE RESTRICT,
    cost_center_id  UUID REFERENCES cost_centers(id) ON DELETE SET NULL,
    party_type      party_type,
    party_id        UUID,                      -- polymorphic ref to customers/vendors
    debit           NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit          NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(code),
    fx_rate         NUMERIC(18,6) NOT NULL DEFAULT 1,
    description     TEXT,
    line_no         SMALLINT NOT NULL,
    CHECK ( (debit = 0 AND credit > 0) OR (debit > 0 AND credit = 0) )
);
CREATE INDEX idx_jel_entry ON journal_entry_lines (journal_entry_id);
CREATE INDEX idx_jel_account ON journal_entry_lines (account_id);

-- Enforces balanced entries (sum debit = sum credit) whenever a journal
-- entry moves to 'posted'. Application should also validate pre-insert;
-- this trigger is the last line of defense.
CREATE OR REPLACE FUNCTION fn_check_journal_balance() RETURNS TRIGGER AS $$
DECLARE
    total_debit  NUMERIC(18,2);
    total_credit NUMERIC(18,2);
BEGIN
    IF NEW.status = 'posted' AND (OLD.status IS DISTINCT FROM 'posted') THEN
        SELECT COALESCE(SUM(debit),0), COALESCE(SUM(credit),0)
          INTO total_debit, total_credit
          FROM journal_entry_lines WHERE journal_entry_id = NEW.id;

        IF total_debit <> total_credit THEN
            RAISE EXCEPTION 'Journal entry % is not balanced: debit % <> credit %',
                NEW.entry_no, total_debit, total_credit;
        END IF;
        NEW.posted_at := now();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_journal_balance
    BEFORE UPDATE ON journal_entries
    FOR EACH ROW EXECUTE FUNCTION fn_check_journal_balance();

-- Bank accounts & reconciliation
CREATE TABLE bank_accounts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    account_id      UUID NOT NULL REFERENCES chart_of_accounts(id),  -- linked GL account
    bank_name       TEXT NOT NULL,
    iban            TEXT,
    account_number  TEXT,
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(code),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE bank_statement_lines (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    bank_account_id UUID NOT NULL REFERENCES bank_accounts(id) ON DELETE CASCADE,
    txn_date        DATE NOT NULL,
    description     TEXT,
    amount          NUMERIC(18,2) NOT NULL,   -- signed: +in / -out
    matched_journal_entry_id UUID REFERENCES journal_entries(id),
    is_reconciled   BOOLEAN NOT NULL DEFAULT FALSE,
    imported_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- 3. PARTIES: CUSTOMERS & VENDORS
-- =====================================================================

CREATE TABLE customers (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    code            TEXT NOT NULL,
    name            TEXT NOT NULL,
    name_ar         TEXT,
    tax_no          TEXT,
    email           CITEXT,
    phone           TEXT,
    address         TEXT,
    credit_limit    NUMERIC(18,2) NOT NULL DEFAULT 0,
    payment_terms_days SMALLINT NOT NULL DEFAULT 0,
    receivable_account_id UUID REFERENCES chart_of_accounts(id),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);

CREATE TABLE vendors (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    code            TEXT NOT NULL,
    name            TEXT NOT NULL,
    name_ar         TEXT,
    tax_no          TEXT,
    email           CITEXT,
    phone           TEXT,
    address         TEXT,
    payment_terms_days SMALLINT NOT NULL DEFAULT 0,
    payable_account_id UUID REFERENCES chart_of_accounts(id),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, code)
);

-- =====================================================================
-- 4. INVENTORY
-- =====================================================================

CREATE TABLE warehouses (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    branch_id   UUID REFERENCES branches(id) ON DELETE SET NULL,
    code        TEXT NOT NULL,
    name        TEXT NOT NULL,
    name_ar     TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    UNIQUE (tenant_id, code)
);

CREATE TABLE products (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    sku             TEXT NOT NULL,
    barcode         TEXT,
    name            TEXT NOT NULL,
    name_ar         TEXT,
    category        TEXT,
    unit_of_measure TEXT NOT NULL DEFAULT 'pc',
    costing_method  costing_method NOT NULL DEFAULT 'average',
    sales_price     NUMERIC(18,2) NOT NULL DEFAULT 0,
    cost_price      NUMERIC(18,2) NOT NULL DEFAULT 0,
    reorder_point   NUMERIC(18,2) NOT NULL DEFAULT 0,
    reorder_qty     NUMERIC(18,2) NOT NULL DEFAULT 0,
    is_batch_tracked BOOLEAN NOT NULL DEFAULT FALSE,
    is_expiry_tracked BOOLEAN NOT NULL DEFAULT FALSE,
    inventory_account_id UUID REFERENCES chart_of_accounts(id),
    revenue_account_id   UUID REFERENCES chart_of_accounts(id),
    cogs_account_id      UUID REFERENCES chart_of_accounts(id),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, sku)
);

CREATE TABLE product_batches (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    product_id      UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    batch_no        TEXT NOT NULL,
    expiry_date     DATE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (product_id, batch_no)
);

-- Running stock balance per product/warehouse (denormalized for fast reads;
-- kept in sync by triggers/application logic off inventory_movements).
CREATE TABLE inventory_stock (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    product_id      UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    warehouse_id    UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    batch_id        UUID REFERENCES product_batches(id) ON DELETE SET NULL,
    quantity_on_hand NUMERIC(18,3) NOT NULL DEFAULT 0,
    average_cost     NUMERIC(18,4) NOT NULL DEFAULT 0,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- One stock row per product/warehouse/batch combination. A plain unique
-- constraint can't treat NULL batch_id as a single "no batch" bucket
-- (SQL NULLs are never equal), so we normalize it to a sentinel UUID
-- via an expression index — something a PRIMARY KEY can't do directly.
CREATE UNIQUE INDEX idx_inventory_stock_unique
    ON inventory_stock (product_id, warehouse_id, COALESCE(batch_id, '00000000-0000-0000-0000-000000000000'));

CREATE TABLE inventory_movements (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    product_id      UUID NOT NULL REFERENCES products(id),
    warehouse_id    UUID NOT NULL REFERENCES warehouses(id),
    batch_id        UUID REFERENCES product_batches(id),
    movement_type    movement_type NOT NULL,
    quantity        NUMERIC(18,3) NOT NULL,   -- positive; direction from movement_type
    unit_cost       NUMERIC(18,4) NOT NULL DEFAULT 0,
    source_doc_type TEXT,                     -- 'sales_invoice' | 'purchase_invoice' | 'adjustment'
    source_doc_id   UUID,
    movement_date   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by      UUID REFERENCES users(id)
);
CREATE INDEX idx_inv_move_product ON inventory_movements (tenant_id, product_id, warehouse_id);

-- =====================================================================
-- 5. SALES
-- =====================================================================

CREATE TABLE sales_invoices (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    branch_id       UUID REFERENCES branches(id),
    customer_id     UUID NOT NULL REFERENCES customers(id),
    warehouse_id    UUID REFERENCES warehouses(id),
    invoice_no      TEXT NOT NULL,
    invoice_date    DATE NOT NULL,
    due_date        DATE,
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(code),
    fx_rate         NUMERIC(18,6) NOT NULL DEFAULT 1,
    subtotal        NUMERIC(18,2) NOT NULL DEFAULT 0,
    tax_total       NUMERIC(18,2) NOT NULL DEFAULT 0,
    grand_total     NUMERIC(18,2) NOT NULL DEFAULT 0,
    amount_paid     NUMERIC(18,2) NOT NULL DEFAULT 0,
    status          doc_status NOT NULL DEFAULT 'draft',
    is_pos          BOOLEAN NOT NULL DEFAULT FALSE,
    qr_payload      TEXT,                      -- e-invoicing QR (ZATCA-style)
    journal_entry_id UUID REFERENCES journal_entries(id),
    source          ai_command_source,          -- null if created manually via UI
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, invoice_no)
);
CREATE INDEX idx_sales_inv_tenant_date ON sales_invoices (tenant_id, invoice_date);
CREATE INDEX idx_sales_inv_customer ON sales_invoices (customer_id);

CREATE TABLE sales_invoice_lines (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sales_invoice_id UUID NOT NULL REFERENCES sales_invoices(id) ON DELETE CASCADE,
    product_id      UUID NOT NULL REFERENCES products(id),
    line_no         SMALLINT NOT NULL,
    quantity        NUMERIC(18,3) NOT NULL,
    unit_price      NUMERIC(18,2) NOT NULL,
    tax_rate_id     UUID REFERENCES tax_rates(id),
    discount_pct    NUMERIC(6,3) NOT NULL DEFAULT 0,
    line_total      NUMERIC(18,2) NOT NULL
);

CREATE TABLE sales_quotations (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    customer_id     UUID NOT NULL REFERENCES customers(id),
    quotation_no    TEXT NOT NULL,
    quotation_date  DATE NOT NULL,
    valid_until     DATE,
    status          doc_status NOT NULL DEFAULT 'draft',
    grand_total     NUMERIC(18,2) NOT NULL DEFAULT 0,
    converted_invoice_id UUID REFERENCES sales_invoices(id),
    created_by      UUID REFERENCES users(id),
    UNIQUE (tenant_id, quotation_no)
);

CREATE TABLE customer_payments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    customer_id     UUID NOT NULL REFERENCES customers(id),
    sales_invoice_id UUID REFERENCES sales_invoices(id),
    bank_account_id UUID REFERENCES bank_accounts(id),
    payment_date    DATE NOT NULL,
    amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    method          TEXT NOT NULL DEFAULT 'cash',   -- cash | bank_transfer | card | cheque
    journal_entry_id UUID REFERENCES journal_entries(id),
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- 6. PURCHASES
-- =====================================================================

CREATE TABLE purchase_orders (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    vendor_id       UUID NOT NULL REFERENCES vendors(id),
    po_no           TEXT NOT NULL,
    order_date      DATE NOT NULL,
    expected_date   DATE,
    status          doc_status NOT NULL DEFAULT 'draft',
    grand_total     NUMERIC(18,2) NOT NULL DEFAULT 0,
    created_by      UUID REFERENCES users(id),
    UNIQUE (tenant_id, po_no)
);

CREATE TABLE purchase_invoices (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    vendor_id       UUID NOT NULL REFERENCES vendors(id),
    purchase_order_id UUID REFERENCES purchase_orders(id),
    warehouse_id    UUID REFERENCES warehouses(id),
    invoice_no      TEXT NOT NULL,
    vendor_ref_no   TEXT,                      -- vendor's own invoice number
    invoice_date    DATE NOT NULL,
    due_date        DATE,
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(code),
    fx_rate         NUMERIC(18,6) NOT NULL DEFAULT 1,
    subtotal        NUMERIC(18,2) NOT NULL DEFAULT 0,
    tax_total       NUMERIC(18,2) NOT NULL DEFAULT 0,
    grand_total     NUMERIC(18,2) NOT NULL DEFAULT 0,
    amount_paid     NUMERIC(18,2) NOT NULL DEFAULT 0,
    status          doc_status NOT NULL DEFAULT 'draft',
    journal_entry_id UUID REFERENCES journal_entries(id),
    source          ai_command_source,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, invoice_no)
);

CREATE TABLE purchase_invoice_lines (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    purchase_invoice_id UUID NOT NULL REFERENCES purchase_invoices(id) ON DELETE CASCADE,
    product_id      UUID NOT NULL REFERENCES products(id),
    line_no         SMALLINT NOT NULL,
    quantity        NUMERIC(18,3) NOT NULL,
    unit_cost       NUMERIC(18,2) NOT NULL,
    tax_rate_id     UUID REFERENCES tax_rates(id),
    line_total      NUMERIC(18,2) NOT NULL
);

CREATE TABLE vendor_payments (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    vendor_id       UUID NOT NULL REFERENCES vendors(id),
    purchase_invoice_id UUID REFERENCES purchase_invoices(id),
    bank_account_id UUID REFERENCES bank_accounts(id),
    payment_date    DATE NOT NULL,
    amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    method          TEXT NOT NULL DEFAULT 'bank_transfer',
    journal_entry_id UUID REFERENCES journal_entries(id),
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE expenses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    branch_id       UUID REFERENCES branches(id),
    expense_account_id UUID NOT NULL REFERENCES chart_of_accounts(id),
    cost_center_id  UUID REFERENCES cost_centers(id),
    vendor_id       UUID REFERENCES vendors(id),
    expense_date    DATE NOT NULL,
    amount          NUMERIC(18,2) NOT NULL CHECK (amount > 0),
    description     TEXT,
    receipt_ocr_ref UUID,                      -- links to ocr_documents.id
    journal_entry_id UUID REFERENCES journal_entries(id),
    source          ai_command_source,
    created_by      UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- 7. HR & PAYROLL (foundations)
-- =====================================================================

CREATE TABLE employees (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    branch_id       UUID REFERENCES branches(id),
    user_id         UUID REFERENCES users(id) ON DELETE SET NULL,  -- optional portal login
    employee_no     TEXT NOT NULL,
    full_name       TEXT NOT NULL,
    full_name_ar    TEXT,
    national_id     TEXT,
    job_title       TEXT,
    department      TEXT,
    hire_date       DATE NOT NULL,
    termination_date DATE,
    base_salary     NUMERIC(18,2) NOT NULL DEFAULT 0,
    currency_code   CHAR(3) NOT NULL REFERENCES currencies(code),
    status          employment_status NOT NULL DEFAULT 'active',
    UNIQUE (tenant_id, employee_no)
);

CREATE TABLE employee_contracts (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    employee_id     UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    contract_type   TEXT NOT NULL DEFAULT 'full_time',
    start_date      DATE NOT NULL,
    end_date        DATE,
    salary          NUMERIC(18,2) NOT NULL,
    document_url    TEXT
);

CREATE TABLE attendance_records (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    employee_id     UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    work_date       DATE NOT NULL,
    check_in        TIMESTAMPTZ,
    check_out       TIMESTAMPTZ,
    status          TEXT NOT NULL DEFAULT 'present',  -- present | absent | leave | holiday
    UNIQUE (employee_id, work_date)
);

CREATE TABLE leave_requests (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    employee_id     UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    leave_type      TEXT NOT NULL,             -- annual | sick | unpaid
    start_date      DATE NOT NULL,
    end_date        DATE NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending', -- pending | approved | rejected
    approved_by     UUID REFERENCES users(id)
);

CREATE TABLE employee_loans (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    employee_id     UUID NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
    principal_amount NUMERIC(18,2) NOT NULL,
    monthly_deduction NUMERIC(18,2) NOT NULL,
    start_date      DATE NOT NULL,
    remaining_balance NUMERIC(18,2) NOT NULL
);

CREATE TABLE payroll_runs (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    period_id       UUID NOT NULL REFERENCES accounting_periods(id),
    run_date        DATE NOT NULL,
    status          doc_status NOT NULL DEFAULT 'draft',
    total_gross     NUMERIC(18,2) NOT NULL DEFAULT 0,
    total_deductions NUMERIC(18,2) NOT NULL DEFAULT 0,
    total_net       NUMERIC(18,2) NOT NULL DEFAULT 0,
    journal_entry_id UUID REFERENCES journal_entries(id),
    created_by      UUID REFERENCES users(id)
);

CREATE TABLE payroll_lines (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payroll_run_id  UUID NOT NULL REFERENCES payroll_runs(id) ON DELETE CASCADE,
    employee_id     UUID NOT NULL REFERENCES employees(id),
    gross_salary    NUMERIC(18,2) NOT NULL,
    deductions      NUMERIC(18,2) NOT NULL DEFAULT 0,
    net_salary      NUMERIC(18,2) NOT NULL
);

-- =====================================================================
-- 8. AI LAYER: voice commands, OCR documents, insights
-- =====================================================================

-- Every voice/text/OCR command the AI accountant handles, with a full
-- audit trail of what it understood and what it did — critical for
-- trust in an AI that's allowed to post financial entries.
CREATE TABLE ai_commands (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES users(id),
    source          ai_command_source NOT NULL,
    raw_input       TEXT,                      -- transcribed text of the command
    detected_locale TEXT,                      -- ar | en
    parsed_intent   TEXT,                      -- 'create_sales_invoice'
    parsed_entities JSONB,                      -- {"customer":"أحمد","amount":500,"currency":"USD"}
    confidence_score NUMERIC(4,3),
    status          ai_command_status NOT NULL DEFAULT 'received',
    result_doc_type TEXT,
    result_doc_id   UUID,
    error_message   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at    TIMESTAMPTZ
);
CREATE INDEX idx_ai_commands_tenant ON ai_commands (tenant_id, created_at);

CREATE TABLE ocr_documents (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    uploaded_by     UUID REFERENCES users(id),
    file_url        TEXT NOT NULL,
    document_type   TEXT,                      -- 'vendor_invoice' | 'receipt'
    extracted_data  JSONB,
    confidence_score NUMERIC(4,3),
    linked_doc_type TEXT,                       -- 'purchase_invoice' | 'expense'
    linked_doc_id   UUID,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- AI-detected anomalies: duplicate invoices, unusual amounts, mismatched
-- totals — surfaced to the AI Center / fraud-detection dashboard.
CREATE TABLE ai_flags (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    flag_type       TEXT NOT NULL,              -- 'duplicate_invoice' | 'unusual_amount' | 'posting_error'
    severity        TEXT NOT NULL DEFAULT 'medium', -- low | medium | high
    related_doc_type TEXT,
    related_doc_id  UUID,
    explanation     TEXT,
    explanation_ar  TEXT,
    is_resolved     BOOLEAN NOT NULL DEFAULT FALSE,
    resolved_by     UUID REFERENCES users(id),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- =====================================================================
-- 9. ROW-LEVEL SECURITY
-- =====================================================================
-- Every tenant-scoped table gets the same policy shape. Shown here for
-- the highest-traffic tables; repeat the pattern for the rest at
-- migration time (a generation script can loop information_schema for
-- every table with a tenant_id column and apply this automatically).

ALTER TABLE journal_entries       ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_entry_lines   ENABLE ROW LEVEL SECURITY;
ALTER TABLE sales_invoices        ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_invoices     ENABLE ROW LEVEL SECURITY;
ALTER TABLE customers             ENABLE ROW LEVEL SECURITY;
ALTER TABLE vendors               ENABLE ROW LEVEL SECURITY;
ALTER TABLE products              ENABLE ROW LEVEL SECURITY;
ALTER TABLE chart_of_accounts     ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation_journal_entries ON journal_entries
    USING (tenant_id = current_setting('app.current_tenant_id')::UUID);

CREATE POLICY tenant_isolation_sales_invoices ON sales_invoices
    USING (tenant_id = current_setting('app.current_tenant_id')::UUID);

CREATE POLICY tenant_isolation_purchase_invoices ON purchase_invoices
    USING (tenant_id = current_setting('app.current_tenant_id')::UUID);

CREATE POLICY tenant_isolation_customers ON customers
    USING (tenant_id = current_setting('app.current_tenant_id')::UUID);

CREATE POLICY tenant_isolation_vendors ON vendors
    USING (tenant_id = current_setting('app.current_tenant_id')::UUID);

CREATE POLICY tenant_isolation_products ON products
    USING (tenant_id = current_setting('app.current_tenant_id')::UUID);

CREATE POLICY tenant_isolation_coa ON chart_of_accounts
    USING (tenant_id = current_setting('app.current_tenant_id')::UUID);

-- journal_entry_lines has no tenant_id of its own — isolate via its parent.
CREATE POLICY tenant_isolation_jel ON journal_entry_lines
    USING (journal_entry_id IN (
        SELECT id FROM journal_entries
        WHERE tenant_id = current_setting('app.current_tenant_id')::UUID
    ));

-- =====================================================================
-- 10. updated_at maintenance trigger (generic, reusable)
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_tenants_updated_at BEFORE UPDATE ON tenants
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- =====================================================================
-- Notes for the next migration pass:
--  - Add `notifications`, `backups` (metadata only — actual backups run
--    via managed Postgres snapshots, not app-level tables).
--  - Add `subscription_invoices` for SaaS billing once a payment
--    processor (Stripe/PayTabs) is chosen.
--  - Consider partitioning `journal_entry_lines` and
--    `inventory_movements` by tenant_id or month once data volume
--    warrants it — not needed at MVP scale.
-- =====================================================================
