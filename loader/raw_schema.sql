-- Raw layer contract: the tables the loader creates in warehouse/raw.duckdb.
--
-- One schema per source system, as a warehouse "raw" project would have one dataset per
-- connector. The generator must produce exactly these columns, and dbt's sources.yml files
-- declare exactly these tables. Change this file first, then the generator, then dbt.
--
-- Loader conventions (see docs/source-systems.md for the full rules):
--   policy_admin, billing   Fivetran-style: one row per primary key in its latest state,
--                           _fivetran_synced = when the row was last written,
--                           _fivetran_deleted = soft delete flag (deleted rows stay).
--   claims                  Rivery-style CDC in append mode: one row per change event,
--                           so a key appears once per version. __deleted marks deletions.
--   general_ledger          Fivetran-style file connector over monthly CSV exports:
--                           every column arrives as text, plus _file/_line/_modified.
--   generator_audit         Generated-data answer key: facts the generator knows and a
--                           real warehouse would not; used by tests, never by models.

create schema if not exists policy_admin;
create schema if not exists billing;
create schema if not exists claims;
create schema if not exists general_ledger;
create schema if not exists generator_audit;

-- ---------------------------------------------------------------------------------------------
-- policy_admin: the policy administration system
-- ---------------------------------------------------------------------------------------------

create or replace table policy_admin.policyholders (
    policyholder_id         bigint,         -- primary key
    first_name              varchar,
    last_name               varchar,
    date_of_birth           date,
    email                   varchar,        -- always @example.com, or @test.example.com for test records
    address_state           varchar,        -- two-letter code
    address_zip             varchar,        -- five digits, kept as text (leading zeros)
    created_at              timestamp,
    updated_at              timestamp,      -- changes when the address changes
    _fivetran_synced        timestamp,
    _fivetran_deleted       boolean
);

create or replace table policy_admin.policies (
    policy_id               bigint,         -- primary key
    policy_number           varchar,        -- 'PA-0001234' (auto) or 'HO-0001234' (home)
    policyholder_id         bigint,
    line_of_business        varchar,        -- 'AUTO' or 'HOME'
    risk_state              varchar,        -- two-letter code
    sales_channel           varchar,        -- 'ONLINE', 'PHONE', 'AGENCY'
    original_effective_date date,
    policy_status           varchar,        -- current state: 'ACTIVE', 'CANCELLED', 'EXPIRED'
    created_at              timestamp,
    updated_at              timestamp,
    _fivetran_synced        timestamp,
    _fivetran_deleted       boolean
);

create or replace table policy_admin.policy_terms (
    term_id                 bigint,         -- primary key
    policy_id               bigint,
    term_number             integer,        -- 1 for new business, then 2, 3, ... per renewal
    term_effective_date     date,
    term_expiration_date    date,           -- exclusive: coverage ends at 00:00 on this date
    billing_plan            varchar,        -- 'PAY_IN_FULL' or 'MONTHLY'
    term_status             varchar,        -- current state: 'ACTIVE', 'EXPIRED', 'CANCELLED'
    cancellation_effective_date date,       -- null unless cancelled
    cancellation_reason     varchar,        -- 'INSURED_REQUEST', 'NONPAYMENT', 'UNDERWRITING'
    term_written_premium    decimal(12, 2), -- current total of all the term's transactions
    created_at              timestamp,
    updated_at              timestamp,      -- changes on cancel, reinstate, endorse, expire
    _fivetran_synced        timestamp,
    _fivetran_deleted       boolean
);

create or replace table policy_admin.policy_transactions (
    transaction_id          bigint,         -- primary key; rows never change once written
    policy_id               bigint,
    term_id                 bigint,
    transaction_type        varchar,        -- 'NEW_BUSINESS', 'RENEWAL', 'ENDORSEMENT',
                                            -- 'CANCELLATION', 'REINSTATEMENT'
    transaction_date        date,           -- the date the transaction is dated (accounting)
    effective_date          date,           -- when the change takes effect on coverage
    written_premium         decimal(12, 2), -- signed; equals the sum of its lines
    created_at              timestamp,      -- when it was entered into the system
    _fivetran_synced        timestamp,
    _fivetran_deleted       boolean
);

create or replace table policy_admin.policy_transaction_lines (
    transaction_line_id     bigint,         -- primary key
    transaction_id          bigint,
    coverage_code           varchar,        -- see seeds/coverages.csv
    written_premium         decimal(12, 2), -- signed
    _fivetran_synced        timestamp,
    _fivetran_deleted       boolean
);

create or replace table policy_admin.vehicles (
    vehicle_id              bigint,         -- primary key
    policy_id               bigint,         -- AUTO policies only
    model_year              integer,
    make                    varchar,
    body_type               varchar,        -- 'SEDAN', 'SUV', 'PICKUP', 'MINIVAN', 'COUPE'
    created_at              timestamp,
    _fivetran_synced        timestamp,
    _fivetran_deleted       boolean
);

create or replace table policy_admin.dwellings (
    dwelling_id             bigint,         -- primary key
    policy_id               bigint,         -- HOME policies only
    year_built              integer,
    construction_type       varchar,        -- 'FRAME', 'MASONRY', 'SUPERIOR'
    square_feet             integer,
    coverage_a_limit        decimal(12, 2), -- dwelling limit in dollars
    created_at              timestamp,
    _fivetran_synced        timestamp,
    _fivetran_deleted       boolean
);

-- ---------------------------------------------------------------------------------------------
-- billing: the billing system. Amounts are integer cents, unlike every other system.
-- ---------------------------------------------------------------------------------------------

create or replace table billing.installments (
    installment_id          bigint,         -- primary key
    policy_id               bigint,
    term_id                 bigint,
    transaction_id          bigint,         -- the policy transaction this amount bills
    installment_number      integer,        -- 1..n within the transaction
    due_date                date,
    amount_cents            bigint,         -- signed; negative is a credit
    created_at              timestamp,
    updated_at              timestamp,
    _fivetran_synced        timestamp,
    _fivetran_deleted       boolean
);

create or replace table billing.payments (
    payment_id              bigint,         -- primary key
    policy_id               bigint,
    received_at             timestamp,
    amount_cents            bigint,         -- positive = received, negative = refund paid out
    payment_method          varchar,        -- 'ACH', 'CARD', 'CHECK'
    payment_status          varchar,        -- current state: 'SETTLED' or 'RETURNED'
    returned_at             timestamp,      -- null unless returned (e.g. insufficient funds)
    created_at              timestamp,
    updated_at              timestamp,
    _fivetran_synced        timestamp,
    _fivetran_deleted       boolean
);

-- ---------------------------------------------------------------------------------------------
-- claims: the claims system, CDC change log (one row per version of a source row)
-- ---------------------------------------------------------------------------------------------

create or replace table claims.claims (
    claim_id                bigint,         -- primary key in the source; repeats here per version
    claim_number            varchar,        -- 'CL-2024-000123'
    policy_number           varchar,        -- as typed in the claims system; not always clean
    loss_date               date,
    reported_at             timestamp,
    loss_cause              varchar,        -- see seeds/loss_causes.csv; casing is not consistent
    loss_state              varchar,
    catastrophe_code        varchar,        -- null unless part of a catastrophe event
    claim_status            varchar,        -- 'OPEN', 'CLOSED', 'REOPENED'; legacy 'O','C','R'
    closed_at               timestamp,
    adjuster_id             bigint,
    updated_at              timestamp,      -- source change timestamp of this version
    __deleted               boolean,        -- true on the version that records a hard delete
    _rivery_last_update     timestamp,      -- when the loader wrote this version
    _rivery_run_id          varchar,
    _rivery_river_id        varchar
);

create or replace table claims.claim_exposures (
    exposure_id             bigint,         -- primary key in the source; repeats per version
    claim_id                bigint,
    coverage_code           varchar,
    claimant_type           varchar,        -- 'FIRST_PARTY' or 'THIRD_PARTY'
    exposure_status         varchar,        -- 'OPEN' or 'CLOSED'
    opened_at               timestamp,
    closed_at               timestamp,
    updated_at              timestamp,
    __deleted               boolean,
    _rivery_last_update     timestamp,
    _rivery_run_id          varchar,
    _rivery_river_id        varchar
);

create or replace table claims.claim_transactions (
    claim_transaction_id    bigint,         -- primary key in the source; repeats per version
    claim_id                bigint,
    exposure_id             bigint,
    transaction_type        varchar,        -- 'RESERVE', 'PAYMENT', 'RECOVERY'
    cost_category           varchar,        -- 'LOSS' or 'EXPENSE'
    expense_type            varchar,        -- 'DCC' or 'AO' for EXPENSE, null for LOSS
    reserve_reason          varchar,        -- RESERVE rows only: 'INITIAL', 'REVISION',
                                            -- 'PAYMENT_EROSION', 'CLOSE', 'REOPEN', 'VOID_RESTORE'
    amount                  decimal(12, 2), -- RESERVE: signed change; PAYMENT/RECOVERY: positive
    transaction_date        date,
    transaction_status      varchar,        -- 'POSTED' or 'VOIDED' (payments can be voided later)
    voided_at               timestamp,
    created_at              timestamp,
    updated_at              timestamp,
    __deleted               boolean,
    _rivery_last_update     timestamp,
    _rivery_run_id          varchar,
    _rivery_river_id        varchar
);

create or replace table claims.adjusters (
    adjuster_id             bigint,
    adjuster_name           varchar,
    team                    varchar,        -- 'AUTO_PHYSICAL_DAMAGE', 'AUTO_INJURY', 'PROPERTY', 'CATASTROPHE'
    is_active               boolean,
    hired_date              date,
    updated_at              timestamp,
    __deleted               boolean,
    _rivery_last_update     timestamp,
    _rivery_run_id          varchar,
    _rivery_river_id        varchar
);

-- ---------------------------------------------------------------------------------------------
-- general_ledger: monthly journal exports from the ERP, loaded from CSV files as text
-- ---------------------------------------------------------------------------------------------

create or replace table general_ledger.journal_lines (
    journal_id              varchar,        -- 'JE-2024-06-0001'
    line_number             varchar,
    accounting_period       varchar,        -- 'YYYY-MM'
    posting_date            varchar,        -- US format 'MM/DD/YYYY'
    account_number          varchar,        -- see seeds/gl_accounts.csv
    line_of_business        varchar,        -- 'AUTO' or 'HOME'
    debit                   varchar,        -- decimal text or empty; see docs for format changes
    credit                  varchar,
    source_system           varchar,        -- 'POLICY_ADMIN', 'BILLING', 'CLAIMS', 'MANUAL'
    description             varchar,
    _file                   varchar,        -- e.g. 'gl_export_2024_06.csv'
    _line                   bigint,         -- line number within the file
    _modified               timestamp,      -- file modification time
    _fivetran_synced        timestamp
);

-- ---------------------------------------------------------------------------------------------
-- generator_audit: answer key of the generated data. Models must never select from it.
-- ---------------------------------------------------------------------------------------------

create or replace table generator_audit.load_info (
    as_of                   timestamp,      -- the loader showed the sources as of this moment
    valuation_date          date,           -- last date the generator simulated
    generator_seed          integer,
    scale                   double,
    loaded_at               timestamp       -- wall-clock time of the load
);

create or replace table generator_audit.control_totals (
    metric                  varchar,        -- e.g. 'written_premium'; see docs/source-systems.md
    grain                   varchar,        -- 'accounting_period' or 'accident_year'
    period                  varchar,        -- 'YYYY-MM' or 'YYYY'
    line_of_business        varchar,        -- 'AUTO' or 'HOME'
    value                   decimal(18, 2),
    as_of                   timestamp       -- the totals are valid only for a load at this as_of
);

create or replace table generator_audit.planted_issues (
    issue_code              varchar,        -- e.g. 'TEST_POLICIES'; see docs/data-issues.md
    source_table            varchar,        -- e.g. 'policy_admin.policies'
    record_count            bigint,         -- rows affected in the full (valuation-date) load
    description             varchar
);
