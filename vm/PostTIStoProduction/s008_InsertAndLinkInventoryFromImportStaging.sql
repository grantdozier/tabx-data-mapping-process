-- s008_InsertAndLinkInventoryFromImportStaging.sql
--
-- When     Who   What
-- 20260309 auto  Created: insert and link Common.Inventory and TabX.LocationInventory
--                records from ImportStaging in four sequential steps.
--
-- Purpose:
--   Four steps that fully link ImportStaging rows to their inventory records:
--
--   STEP 0 — Resolve sentinel container and category FKs on ImportStaging
--     Before inserting inventory, replace NULL or sentinel fkContainerId
--     (29, 32, 35) and NULL or sentinel fkProductCategoryId (0, 2000) with
--     the defaults stored on Common.ProductTypes for the row's product type.
--     Sentinel values: 29 = DB default/unknown container; 32, 35 = generic
--     placeholders. 0, 2000 = DB default/unknown category.
--     Fallback: any fkContainerId still NULL after type-based resolution
--     (rows where fkProductId is unresolved) is set to 29, the generic
--     container. After STEP 0, fkContainerId is guaranteed non-NULL.
--
--   STEP A — Insert new Common.Inventory records (replaces s010)
--     Insert (fkProductId, fkContainerId) pairs that do not yet exist in
--     Common.Inventory. These are new product-container combinations entering
--     the catalog. Deduplicates across ImportStaging rows (GROUP BY) and skips
--     pairs that already exist (LEFT JOIN + IS NULL guard).
--
--   STEP B — Update ImportStaging.fkInventoryId (replaces s020)
--     Match each ImportStaging row to its Common.Inventory record via
--     (fkProductId, fkContainerId). After STEP A all rows with valid product
--     and container FKs should resolve.
--
--   STEP C — Insert new TabX.LocationInventory records (replaces s030)
--     For each ImportStaging row with a resolved fkInventoryId, insert a
--     LocationInventory record if one does not already exist for that
--     (fkInventoryId, fkLocationId) combination. Location-aware: the same
--     inventory item at two different venues produces two LocInv records.
--
--   STEP D — Update ImportStaging.fkLocationInventoryId (replaces s040)
--     Match each ImportStaging row to its LocationInventory record via
--     (fkInventoryId, ExternalMenuId, TabDetailDescription).
--
-- Row count relationships (expected):
--   LocationInventory inserts (STEP C)  <=  rows with fkInventoryId  <=  total ImportStaging rows
--
--   STEP C inserts fewer rows than ImportStaging because:
--     1. Rows with NULL fkProductId are excluded (cannot resolve fkInventoryId).
--     2. Multiple ImportStaging rows sharing the same
--        (fkInventoryId, fkLocationId, ExternalMenuId, TabDetailDescription)
--        collapse into one LocationInventory record via GROUP BY.
--     3. On re-run, already-existing LocationInventory records are skipped.
--
--   STEP D updates fkLocationInventoryId on ALL rows that have a matching
--   LocationInventory record, so its count tracks rows with fkInventoryId, not
--   LocationInventory inserts.
--
-- Run order: AFTER s007_InsertNewProductAliasesFromImportStaging.sql, BEFORE s050.
--   fkProductId and fkContainerId must be resolved on ImportStaging rows before
--   this script runs. Rows missing fkProductId are skipped and surfaced in Preview 4.
--
-- This script is safe to re-run. STEP A and STEP C skip existing records.
-- STEP B and STEP D are idempotent updates.
--
--use TabX
--GO


-- =========================================================================
-- SECTION 1: PREVIEW
-- Always safe to run. No data is modified.
-- Review this output before executing SECTION 2.
--
-- Returns five result sets:
--   Preview 1 — New Common.Inventory candidates (STEP A)
--   Preview 2 — ImportStaging link status summary (all four steps)
--   Preview 3 — New LocationInventory candidates (STEP C, current CInventory only)
--   Preview 3b — LocationInventory records that already exist (will be skipped by STEP C)
--   Preview 4 — ImportStaging rows with NULL fkProductId (cannot be linked)
--
-- Container resolution (OUTER APPLY `res`) appears in Previews 1–3:
--   STEP 0 will replace sentinel fkContainerId values (NULL, 29, 32, 35) on
--   ImportStaging with the product type's default container from
--   Common.ProductTypes.fkContainer_Default, falling back to 29 if the product
--   or its type cannot be found. The previews replicate this logic so they show
--   the post-STEP-0 state without actually modifying data.
--
--   The OUTER APPLY is structured to always return exactly one row (no FROM
--   clause in the outer select; a correlated scalar subquery does the lookup).
--   This guarantees res.ContainerId is never NULL — every row resolves to at
--   least the generic container 29.
--
--   Each preview is a separate GO batch so the OUTER APPLY must be repeated;
--   it cannot be factored into a shared CTE across batch boundaries.
-- =========================================================================

-- -----------------------------------------------------------------------
-- Preview 1: New Common.Inventory candidates (would be inserted by STEP A)
-- Each row is one unique (fkProductId, resolved-fkContainerId) pair that
-- does not yet exist in Common.Inventory.
--
-- Columns:
--   fkProductId    — product that will gain an inventory record
--   ProductName    — display name (joined from Common.Products)
--   fkContainerId  — resolved container (after sentinel substitution / fallback)
--   EarliestImport — DateCreated of the oldest ImportStaging row in the group
--   SourceRowCount — number of ImportStaging rows that map to this pair
--   SampleItems    — up to 3 sample TabDetailDescriptions for identification
-- -----------------------------------------------------------------------
; with

new_cinv as (
   -- Aggregate all ImportStaging rows that map to the same (product, container)
   -- pair and have no matching record in Common.Inventory yet.
   select
      src.fkProductId
     ,src.ResolvedContainerId       as fkContainerId
     ,count(*)             as SourceRowCount
     ,min(src.DateCreated) as EarliestImport
     -- Collect a sample of item descriptions (max 3) for review purposes.
     -- rn is the row-number within each (product, container) group ordered by
     -- pkImportStagingId, so rn<=3 always picks the three earliest rows.
     ,string_agg(case when src.rn <= 3 then left(src.TabDetailDescription, 60) end, ' | ')
         within group (order by src.pkImportStagingId)   as SampleItems
   from (
      -- Inner subquery: resolve sentinel container IDs, assign row numbers within
      -- each (product, container) group for the SampleItems cap.
      select
             tis.pkImportStagingId
            ,tis.fkProductId
            ,tis.DateCreated
            ,tis.TabDetailDescription
            ,res.ContainerId as ResolvedContainerId
            -- rn used above to cap SampleItems at 3 per group.
            ,row_number() over (
                 partition by tis.fkProductId, res.ContainerId
                 order by tis.pkImportStagingId
             ) as rn
      from TabX.ImportStaging as tis
      -- Resolve sentinel/null container to the product type's default, with 29
      -- as the ultimate fallback. Always returns exactly one row so ContainerId
      -- is never NULL. See section header for full explanation.
      outer apply (
          select
              case
                  when tis.fkContainerId is not null and tis.fkContainerId not in (29, 32, 35)
                  then tis.fkContainerId   -- already a valid container; use as-is
                  else isnull(
                      (select pt.fkContainer_Default
                       from Common.Products as p
                       inner join Common.ProductTypes as pt
                           on pt.pkProductTypeId = p.fkProductTypeId
                       where p.pkProductId = tis.fkProductId),
                      29   -- fallback: product/type not found — use generic container
                  )
              end as ContainerId
      ) as res
      -- Anti-join: only keep rows whose (product, resolved-container) pair does
      -- not yet exist in Common.Inventory (ci.pkInventoryId IS NULL means no match).
      left outer join Common.Inventory as ci
         on  ci.fkProductId   = tis.fkProductId
         and ci.fkContainerId = res.ContainerId
      where tis.fkProductId  is not null   -- must have a product to insert inventory
        and ci.pkInventoryId  is null       -- skip pairs already in Common.Inventory
   ) as src
   group by src.fkProductId, src.ResolvedContainerId
)

select
    nc.fkProductId
   ,p.ProductName
   ,nc.fkContainerId
   ,nc.EarliestImport
   ,nc.SourceRowCount
   ,nc.SampleItems
from new_cinv as nc
left outer join Common.Products as p
   on p.pkProductId = nc.fkProductId
order by p.ProductName, nc.fkContainerId;
GO



-- -----------------------------------------------------------------------
-- Preview 2: ImportStaging link status summary
-- One summary row showing counts across all pipeline stages so you can
-- gauge how many rows are ready, already linked, and unresolvable.
--
-- Columns:
--   TotalRows                    — all rows in ImportStaging
--   DuplicateImportRows          — rows beyond the first occurrence of each
--                                  (fkLocationId, ExternalMenuId, TabDetailDescription)
--                                  combination; these collapse to one LocationInventory
--                                  record in STEP C. A non-zero value here explains
--                                  why LocationInventory insert count < TotalRows.
--   NullProductId                — rows with no fkProductId; cannot be processed
--   AlreadyHasfkInventoryId      — rows already linked to Common.Inventory
--                                  (from a previous run)
--   WillGainfkInventoryId        — rows that will be linked by STEP B because
--                                  a matching Common.Inventory record already exists
--                                  (including those just inserted by STEP A)
--   CannotResolvefkInventoryId   — rows that will remain NULL after STEP A+B
--                                  because fkProductId is missing
--   AlreadyHasfkLocationInventoryId — rows already fully linked to LocationInventory
--
-- Note: MatchesExistingInventory is computed as a 0/1 integer per row in the
-- CTE, then summed in the outer query (EXISTS cannot nest inside an aggregate).
-- -----------------------------------------------------------------------
; with link_status as (
   select
      tis.fkProductId
     ,tis.fkInventoryId
     ,tis.fkLocationInventoryId
     ,tis.fkLocationId
     ,tis.ExternalMenuId
     ,tis.TabDetailDescription
     -- 1 when this row will gain an fkInventoryId via STEP B (a matching
     -- Common.Inventory record already exists); 0 otherwise.
     ,case
         when tis.fkInventoryId is null
          and tis.fkProductId   is not null
          and ci_chk.pkInventoryId is not null then 1
         else 0
      end                        as MatchesExistingInventory
   from TabX.ImportStaging as tis
   -- Resolve sentinel/null container — same always-return logic as Preview 1.
   outer apply (
       select
           case
               when tis.fkContainerId is not null and tis.fkContainerId not in (29, 32, 35)
               then tis.fkContainerId
               else isnull(
                   (select pt.fkContainer_Default
                    from Common.Products as p
                    inner join Common.ProductTypes as pt
                        on pt.pkProductTypeId = p.fkProductTypeId
                    where p.pkProductId = tis.fkProductId),
                   29
               )
           end as ContainerId
   ) as res
   -- Left join instead of EXISTS so the optimizer can use a hash/merge join
   -- rather than per-row index seeks on Common.Inventory.
   left outer join Common.Inventory as ci_chk
       on  ci_chk.fkProductId   = tis.fkProductId
       and ci_chk.fkContainerId = res.ContainerId
)
select
    count(*)                                                                 as TotalRows
   -- DuplicateImportRows: rows beyond the first occurrence of each
   -- (location, menu, description) combination. These are the rows that STEP C
   -- collapses via GROUP BY — they do not produce additional LocationInventory
   -- records, which is why STEP C insert count < TotalRows.
   ,count(*) - count(distinct concat(
        isnull(cast(fkLocationId as varchar(20)), '~null~'),
        '|',
        isnull(ExternalMenuId, '~null~'),
        '|',
        isnull(TabDetailDescription, '~null~')
    ))                                                                       as DuplicateImportRows
   ,sum(case when fkProductId  is null then 1 else 0 end)                   as NullProductId
   ,sum(case when fkInventoryId is not null then 1 else 0 end)              as AlreadyHasfkInventoryId
   ,sum(MatchesExistingInventory)                                            as WillGainfkInventoryId
   ,sum(case when fkInventoryId is null
              and fkProductId   is null then 1 else 0 end)                  as CannotResolvefkInventoryId
   ,sum(case when fkLocationInventoryId is not null then 1 else 0 end)      as AlreadyHasfkLocationInventoryId
from link_status;
GO


-- -----------------------------------------------------------------------
-- Preview 3: LocationInventory candidates — one row per record that STEP C
-- will insert, mirroring STEP C's GROUP BY key exactly.
--
-- Multiple ImportStaging rows that describe the same item at the same
-- location/menu/description are collapsed into a single output row
-- (matching STEP C's deduplication). The SourceRowCount column shows how
-- many ImportStaging rows contributed to each candidate so you can identify
-- where duplicates exist in the source data.
--
-- Uses LEFT JOIN to Common.Inventory so rows whose inventory record does not
-- yet exist (shown as candidates in Preview 1) are included here too. The
-- InsertStatus column distinguishes the two cases:
--
--   'New Inventory + New LocInv (STEP A then C)' — no Common.Inventory record
--     exists yet; STEP A will create it, then STEP C will create the LocInv.
--   'New LocInv only (STEP C)' — Common.Inventory already exists; only the
--     LocationInventory record needs to be inserted by STEP C.
--
-- The row count of this preview should match the STEP C insert count exactly.
--
-- Note: `prod` / `pt3` aliases are used inside the OUTER APPLY scalar subquery
-- to avoid a name conflict with the outer `left outer join Common.Products as p`.
-- -----------------------------------------------------------------------
; with candidates as (
   select
       tis.pkImportStagingId
      ,tis.fkLocationId
      ,tis.fkProductId
      ,res.ContainerId          as ResolvedContainerId
      ,ci.pkInventoryId
      ,tis.ExternalMenuId
      ,tis.TabDetailDescription
      ,tis.DateCreated
      -- Rank within each unique LocInv candidate group (STEP C's GROUP BY key).
      -- rn = 1 picks the earliest ImportStaging row as the representative record.
      ,row_number() over (
           partition by tis.fkProductId
                       ,res.ContainerId
                       ,tis.fkLocationId
                       ,tis.ExternalMenuId
                       ,tis.TabDetailDescription
           order by tis.pkImportStagingId
       ) as rn
      -- Count of ImportStaging rows that map to this LocInv candidate.
      -- SourceRowCount > 1 means duplicates exist in ImportStaging for this item.
      ,count(*) over (
           partition by tis.fkProductId
                       ,res.ContainerId
                       ,tis.fkLocationId
                       ,tis.ExternalMenuId
                       ,tis.TabDetailDescription
       ) as SourceRowCount
   from TabX.ImportStaging as tis
   -- Resolve sentinel/null container — same always-return logic as Preview 1.
   outer apply (
       select
           case
               when tis.fkContainerId is not null and tis.fkContainerId not in (29, 32, 35)
               then tis.fkContainerId
               else isnull(
                   (select pt3.fkContainer_Default
                    from Common.Products as prod
                    inner join Common.ProductTypes as pt3
                        on pt3.pkProductTypeId = prod.fkProductTypeId
                    where prod.pkProductId = tis.fkProductId),
                   29
               )
           end as ContainerId
   ) as res
   -- LEFT JOIN so rows with no existing Common.Inventory record still appear
   -- (ci.pkInventoryId will be NULL for those rows, shown in InsertStatus).
   left outer join Common.Inventory as ci
      on  ci.fkProductId   = tis.fkProductId
      and ci.fkContainerId = res.ContainerId
   -- Anti-join: only keep rows that have no matching LocationInventory entry yet.
   -- When ci.pkInventoryId is NULL (no inventory), li.fkInventoryId is also NULL
   -- (nothing to match on), so these rows pass the WHERE filter automatically.
   left outer join TabX.LocationInventory as li
      on  li.fkInventoryId        = ci.pkInventoryId
      and li.fkLocationId         = tis.fkLocationId
      and isnull(li.ExternalMenuId, '') = isnull(tis.ExternalMenuId, '')
      and li.TabDetailDescription collate SQL_Latin1_General_Cp1251_CS_AS
        = tis.TabDetailDescription collate SQL_Latin1_General_Cp1251_CS_AS
   where tis.fkProductId  is not null   -- exclude rows with no product (shown in Preview 4)
     and li.fkInventoryId is null       -- exclude rows already linked to LocationInventory (shown in Preview 3b)
)
select
    c.pkImportStagingId       -- earliest ImportStaging row in this candidate group
   ,c.fkLocationId
   ,c.pkInventoryId           as fkInventoryId   -- NULL when inventory doesn't exist yet
   ,p.ProductName
   ,c.ExternalMenuId
   ,c.TabDetailDescription
   ,c.DateCreated
   ,c.SourceRowCount          -- > 1 indicates duplicate ImportStaging rows for this item
   ,case
       when c.pkInventoryId is null
       then 'New Inventory + New LocInv (STEP A then C)'
       else 'New LocInv only (STEP C)'
    end                       as InsertStatus
from candidates as c
left outer join Common.Products as p
   on p.pkProductId = c.fkProductId
where c.rn = 1   -- one row per LocInv candidate; mirrors STEP C's GROUP BY deduplication
order by c.fkLocationId, p.ProductName, c.ExternalMenuId;
GO


-- -----------------------------------------------------------------------
-- Preview 3b: LocationInventory records already present (skipped by STEP C)
-- Mirror image of Preview 3: shows ImportStaging rows that have a matching
-- Common.Inventory record AND a matching LocationInventory record, meaning
-- STEP C will skip them. Use this to confirm which records are pre-existing
-- and to verify that no unintended duplicates exist in LocationInventory.
--
-- Count relationship:
--   Preview 3 row count + Preview 3b row count = TotalRows - NullProductId
--   (all ImportStaging rows with a non-null fkProductId, regardless of whether
--   their Common.Inventory record exists yet — Preview 3 covers both cases).
--
-- Columns:
--   ExistingLocationInventoryId — PK of the matching LocationInventory record
--   ExistingRecordCreated       — when that LocationInventory record was created
--   ImportStagingDate           — DateCreated of the ImportStaging source row
-- -----------------------------------------------------------------------
select
    tis.fkLocationId
   ,li.pkLocationInventoryId     as ExistingLocationInventoryId
   ,ci.pkInventoryId             as fkInventoryId
   ,p.ProductName
   ,tis.ExternalMenuId
   ,tis.TabDetailDescription
   ,li.DateCreated               as ExistingRecordCreated
   ,tis.DateCreated              as ImportStagingDate
from TabX.ImportStaging as tis
-- Resolve sentinel/null container — same always-return logic as Preview 3.
-- Uses alias `prod3b` / `pt3b` inside the scalar subquery to avoid conflict
-- with the outer `left outer join Common.Products as p`.
outer apply (
    select
        case
            when tis.fkContainerId is not null and tis.fkContainerId not in (29, 32, 35)
            then tis.fkContainerId
            else isnull(
                (select pt3b.fkContainer_Default
                 from Common.Products as prod3b
                 inner join Common.ProductTypes as pt3b
                     on pt3b.pkProductTypeId = prod3b.fkProductTypeId
                 where prod3b.pkProductId = tis.fkProductId),
                29
            )
        end as ContainerId
) as res
-- Only rows that have a Common.Inventory record (existing or newly created by STEP A).
inner join Common.Inventory as ci
   on  ci.fkProductId   = tis.fkProductId
   and ci.fkContainerId = res.ContainerId
-- INNER JOIN (not anti-join): keep only rows that DO have a matching
-- LocationInventory record — the opposite filter from Preview 3.
inner join TabX.LocationInventory as li
   on  li.fkInventoryId        = ci.pkInventoryId
   and li.fkLocationId         = tis.fkLocationId
   and isnull(li.ExternalMenuId, '') = isnull(tis.ExternalMenuId, '')
   and li.TabDetailDescription collate SQL_Latin1_General_Cp1251_CS_AS
     = tis.TabDetailDescription collate SQL_Latin1_General_Cp1251_CS_AS
left outer join Common.Products as p
   on p.pkProductId = tis.fkProductId
order by tis.fkLocationId, p.ProductName, tis.ExternalMenuId;
GO


-- -----------------------------------------------------------------------
-- Preview 4: ImportStaging rows with NULL fkProductId
-- These rows cannot be linked to Common.Inventory and will be skipped by
-- all subsequent steps. Investigate upstream product classification before
-- proceeding.
--
-- After STEP 0 runs, fkContainerId is guaranteed non-NULL (sentinel and null
-- values are resolved via ProductTypes, with 29 as the ultimate fallback), so
-- fkContainerId is no longer a reason for rows to appear here. Only rows with
-- a missing product FK are listed.
-- -----------------------------------------------------------------------
select
    tis.pkImportStagingId
   ,tis.fkLocationId
   ,tis.fkProductId
   ,tis.fkContainerId
   ,tis.TabDetailDescription
   ,'NULL fkProductId'         as Reason
from TabX.ImportStaging as tis
where tis.fkProductId is null
order by tis.fkLocationId, tis.pkImportStagingId;
GO



-- =========================================================================
-- SECTION 2: INSERT and UPDATE
--
-- Review SECTION 1 output before running this block.
-- All four steps run inside a single transaction: if any step fails the
-- entire batch is rolled back automatically.
-- =========================================================================
BEGIN TRANSACTION;
BEGIN TRY

   -- -----------------------------------------------------------------------
   -- STEP 0: Resolve sentinel container and category FKs on ImportStaging
   --
   -- Part 1 — Type-based resolution:
   --   Many rows arrive from upstream with placeholder container IDs (NULL, 29,
   --   32, or 35) or category IDs (NULL or 2000) that were assigned when the
   --   product type was unknown. Now that fkProductId is resolved, we can look
   --   up the product's type and apply its configured defaults.
   --
   --   The CASE expressions preserve already-valid values: a row may be touched
   --   because its category is a sentinel even though its container is fine, so
   --   the container branch falls to `else tis.fkContainerId` (no change).
   --
   -- Part 2 — NULL container fallback:
   --   After Part 1, any row that still has a NULL fkContainerId (typically
   --   rows where fkProductId is also NULL and could not be joined to
   --   Common.ProductTypes) is assigned container 29, the generic/unknown
   --   container. This guarantees fkContainerId is non-NULL on all rows
   --   before STEP A runs.
   --
   -- Both parts are idempotent: after the first run sentinels are replaced and
   -- NULLs are filled, so subsequent re-runs find nothing to change.
   -- -----------------------------------------------------------------------

   -- Part 1: resolve sentinels via ProductTypes for rows with a known product.
   update tis
   set
       tis.fkContainerId       = case
           when tis.fkContainerId is null or tis.fkContainerId in (29, 32, 35)
           then isnull(pt.fkContainer_Default, 29)   -- use product-type default; fall back to generic if unconfigured
           else tis.fkContainerId           -- already a valid container; preserve it
       end,
       tis.fkProductCategoryId = case
           when tis.fkProductCategoryId is null or tis.fkProductCategoryId in (0, 2000)
           then pt.fkProductCategoryId_Default   -- use product-type default
           else tis.fkProductCategoryId          -- already a valid category; preserve it
       end
   from TabX.ImportStaging as tis
   inner join Common.Products as p
       on p.pkProductId = tis.fkProductId
   inner join Common.ProductTypes as pt
       on pt.pkProductTypeId = p.fkProductTypeId
   -- Only touch rows that have a valid product AND at least one sentinel value.
   -- The INNER JOINs already require fkProductId to be non-null and present in
   -- Common.Products; the explicit filter is an optimizer hint.
   where tis.fkProductId is not null
     and (   tis.fkContainerId is null
          or tis.fkContainerId in (29, 32, 35)
          or tis.fkProductCategoryId is null
          or tis.fkProductCategoryId in (0, 2000));

   declare @SentinelResolved int = @@rowcount;
   print concat('Step 0 (part 1): ', @SentinelResolved, ' ImportStaging row(s) had sentinel container/category resolved via ProductTypes.');

   -- Part 2: fallback — assign container 29 to any row whose fkContainerId is
   -- NULL or references a container that does not exist in Common.Containers.
   -- Handles: rows where fkProductId could not be joined in Part 1 (leaving NULL),
   -- and rows where fkContainerId holds a value valid in another environment but
   -- absent here (e.g. a source-system container not yet synced to this database).
   update tis
   set    tis.fkContainerId = 29
   from   TabX.ImportStaging as tis
   where  tis.fkContainerId is null
       or not exists (
              select 1 from Common.Containers as c
              where c.pkContainerId = tis.fkContainerId
          );

   declare @NullContainerFallback int = @@rowcount;
   print concat('Step 0 (part 2): ', @NullContainerFallback, ' ImportStaging row(s) had NULL or unresolvable fkContainerId set to generic container 29.');


   -- -----------------------------------------------------------------------
   -- STEP A: Insert new Common.Inventory records
   --
   -- Common.Inventory is the product-container catalog: one record per
   -- (product, container) combination across all locations. A product sold in
   -- a bottle vs. a can vs. on tap is three separate inventory records.
   --
   -- The GROUP BY deduplicates ImportStaging: many rows may reference the same
   -- (fkProductId, fkContainerId) pair, but only one Inventory record is needed.
   -- MIN(DateCreated) is used so the record reflects the earliest known import.
   --
   -- The LEFT JOIN + IS NULL anti-join skips pairs that already exist, making
   -- this step safe to re-run without creating duplicate inventory records.
   -- -----------------------------------------------------------------------
   insert into Common.Inventory
          (fkProductId
          ,fkContainerId
          ,IsActive
          ,fkCreatedByUserId
          ,DateCreated
          ,fkModifiedByUserId
          ,DateModified
          )
   select
       tis.fkProductId
      ,tis.fkContainerId
      ,1                      as IsActive
      ,1                      as fkCreatedByUserId
      ,min(tis.DateCreated)   as DateCreated   -- earliest ImportStaging row in this group
      ,1                      as fkModifiedByUserId
      ,getdate()              as DateModified
   from TabX.ImportStaging as tis
   -- Anti-join: skip (product, container) pairs already in Common.Inventory.
   left outer join Common.Inventory as ci
      on  ci.fkProductId   = tis.fkProductId
      and ci.fkContainerId = tis.fkContainerId
   where tis.fkProductId   is not null   -- must have a product (container is always non-null after STEP 0)
     and ci.pkInventoryId  is null       -- no existing record — safe to insert
   group by tis.fkProductId, tis.fkContainerId;

   declare @CInvInserted int = @@rowcount;
   print concat('Step A: ', @CInvInserted, ' new Common.Inventory record(s) inserted.');


   -- -----------------------------------------------------------------------
   -- STEP B: Update ImportStaging.fkInventoryId
   --
   -- Now that Common.Inventory has all necessary records (newly inserted by
   -- STEP A or pre-existing), stamp each ImportStaging row with the PK of its
   -- inventory record. This link is used by STEP C and STEP D.
   --
   -- The INNER JOIN means rows with NULL fkProductId are naturally skipped
   -- (they have no inventory record to link to).
   -- This UPDATE is idempotent — re-running it overwrites with the same value.
   -- -----------------------------------------------------------------------
   update tis
   set    tis.fkInventoryId = ci.pkInventoryId
   from TabX.ImportStaging as tis
   inner join Common.Inventory as ci
      on  ci.fkProductId   = tis.fkProductId
      and ci.fkContainerId = tis.fkContainerId;

   declare @InvIdUpdated int = @@rowcount;
   print concat('Step B: ', @InvIdUpdated, ' ImportStaging row(s) updated with fkInventoryId.');


   -- -----------------------------------------------------------------------
   -- STEP C: Insert new TabX.LocationInventory records
   --
   -- LocationInventory is the location-aware layer: the same inventory item
   -- at two different venues produces two separate LocationInventory records,
   -- one per location.
   --
   -- The GROUP BY key is (pkInventoryId, fkLocationId, ExternalMenuId,
   -- TabDetailDescription). Multiple ImportStaging rows for the same item
   -- at the same location/menu/description collapse into one LocationInventory
   -- record. This means STEP C inserts FEWER rows than there are ImportStaging
   -- rows — this is expected and correct. The DuplicateImportRows value in
   -- Preview 2 shows exactly how many rows will be collapsed.
   --
   -- The LEFT JOIN + IS NULL anti-join skips combinations that already exist,
   -- making this step safe to re-run.
   --
   -- The explicit collation on TabDetailDescription is required because the
   -- database is CS_AS (case-sensitive); without it SQL Server would use the
   -- column's default collation and could fail to detect an existing record
   -- that differs only in case.
   -- -----------------------------------------------------------------------
   insert into TabX.LocationInventory
          (fkInventoryId
          ,fkLocationId
          ,ExternalMenuId
          ,IsActive
          ,fkCreatedByUserId
          ,DateCreated
          ,fkModifiedByUserId
          ,DateModified
          ,TabDetailDescription
          )
   select
       ci.pkInventoryId
      ,tis.fkLocationId
      ,tis.ExternalMenuId
      ,1                           as IsActive
      ,min(tis.fkCreatedByUserId)  as fkCreatedByUserId
      ,min(tis.DateCreated)        as DateCreated
      ,min(tis.fkModifiedByUserId) as fkModifiedByUserId
      ,getdate()                   as DateModified
      ,tis.TabDetailDescription
   from TabX.ImportStaging as tis
   -- Only process rows whose fkInventoryId was resolved by STEP B.
   inner join Common.Inventory as ci
      on ci.pkInventoryId = tis.fkInventoryId
   -- Anti-join: skip (inventory, location, menu, description) combinations
   -- that already have a LocationInventory record.
   left outer join TabX.LocationInventory as li
      on  li.fkInventoryId        = ci.pkInventoryId
      and li.fkLocationId         = tis.fkLocationId
      and isnull(li.ExternalMenuId, '') = isnull(tis.ExternalMenuId, '')
      and li.TabDetailDescription collate SQL_Latin1_General_Cp1251_CS_AS
        = tis.TabDetailDescription collate SQL_Latin1_General_Cp1251_CS_AS
   where li.fkInventoryId is null   -- no existing LocationInventory — safe to insert
   -- GROUP BY deduplicates: multiple ImportStaging rows for the same item at
   -- the same location become one LocationInventory record.
   group by ci.pkInventoryId, tis.fkLocationId, tis.ExternalMenuId, tis.TabDetailDescription;

   declare @LocInvInserted int = @@rowcount;
   print concat('Step C: ', @LocInvInserted, ' new TabX.LocationInventory record(s) inserted.');


   -- -----------------------------------------------------------------------
   -- STEP D: Update ImportStaging.fkLocationInventoryId
   --
   -- Stamp each ImportStaging row with the PK of its LocationInventory record.
   -- After STEP C every (fkInventoryId, fkLocationId, ExternalMenuId,
   -- TabDetailDescription) combination has a LocationInventory record, so all
   -- rows with a resolved fkInventoryId will match here.
   --
   -- Note: multiple ImportStaging rows can point to the same LocationInventory
   -- record (because STEP C grouped them). That is correct — fkLocationInventoryId
   -- is a reference, not a 1:1 mapping.
   --
   -- This UPDATE is idempotent — re-running it overwrites with the same value.
   -- -----------------------------------------------------------------------
   update tis
   set    tis.fkLocationInventoryId = li.pkLocationInventoryId
   from TabX.ImportStaging as tis
   inner join TabX.LocationInventory as li
      on  li.fkInventoryId        = tis.fkInventoryId
      and li.fkLocationId         = tis.fkLocationId
      and isnull(li.ExternalMenuId, '') = isnull(tis.ExternalMenuId, '')
      and li.TabDetailDescription collate SQL_Latin1_General_Cp1251_CS_AS
        = tis.TabDetailDescription collate SQL_Latin1_General_Cp1251_CS_AS;

   declare @LocInvIdUpdated int = @@rowcount;
   print concat('Step D: ', @LocInvIdUpdated, ' ImportStaging row(s) updated with fkLocationInventoryId.');


   -- -----------------------------------------------------------------------
   -- Post-run checks
   -- -----------------------------------------------------------------------

   -- Check 1: Any row with both fkProductId and fkContainerId set should now
   -- have fkInventoryId. A non-zero result means STEP A or B failed to insert
   -- or link a record — investigate Common.Inventory for the missing pair.
   -- fkContainerId is always non-null after STEP 0 so the filter is fkProductId only.
   declare @StillNoInvId int;
   select @StillNoInvId = count(*)
   from TabX.ImportStaging as tis
   where tis.fkInventoryId  is null
     and tis.fkProductId    is not null;

   if @StillNoInvId > 0
      print concat('WARNING: ', @StillNoInvId,
                   ' ImportStaging row(s) have valid fkProductId but still NULL fkInventoryId. ',
                   'Investigate Common.Inventory.');
   else
      print 'Post-run check 1: OK — all rows with valid fkProductId have fkInventoryId.';


   -- Check 2: Rows with NULL fkProductId — these are expected to remain unlinked
   -- if upstream product classification is incomplete. They do not block other rows.
   -- NULL fkContainerId should never occur after STEP 0 Part 2; check 2b verifies this.
   declare @NullProductRows int;
   declare @NullContainerRows int;
   select
       @NullProductRows   = sum(case when tis.fkProductId   is null then 1 else 0 end)
      ,@NullContainerRows = sum(case when tis.fkContainerId is null then 1 else 0 end)
   from TabX.ImportStaging as tis;

   if @NullProductRows > 0
      print concat('Post-run check 2a: ', @NullProductRows,
                   ' ImportStaging row(s) have NULL fkProductId — cannot be linked. ',
                   'Run Preview 4 to investigate.');
   else
      print 'Post-run check 2a: OK — no rows with NULL fkProductId.';

   -- 2b should always pass: STEP 0 Part 2 unconditionally sets NULL containers to 29.
   if @NullContainerRows > 0
      print concat('WARNING (check 2b): ', @NullContainerRows,
                   ' ImportStaging row(s) still have NULL fkContainerId after STEP 0. ',
                   'This should not happen — investigate TabX.ImportStaging directly.');
   else
      print 'Post-run check 2b: OK — no rows with NULL fkContainerId after STEP 0.';


   -- Check 3: Any row with fkInventoryId should also have fkLocationInventoryId
   -- after STEP D. A non-zero result means a (fkInventoryId, fkLocationId,
   -- ExternalMenuId, TabDetailDescription) combination exists in ImportStaging
   -- but has no matching LocationInventory record — check STEP C's GROUP BY key
   -- and collation handling.
   declare @StillNoLocInvId int;
   select @StillNoLocInvId = count(*)
   from TabX.ImportStaging as tis
   where tis.fkInventoryId         is not null
     and tis.fkLocationInventoryId is null;

   if @StillNoLocInvId > 0
      print concat('WARNING: ', @StillNoLocInvId,
                   ' ImportStaging row(s) have fkInventoryId but NULL fkLocationInventoryId. ',
                   'Check TabX.LocationInventory for missing (fkInventoryId, ExternalMenuId, ',
                   'TabDetailDescription) combinations.');
   else
      print 'Post-run check 3: OK — all rows with fkInventoryId have fkLocationInventoryId.';


   -- Check 4: Informational row-count balance.
   -- Expected: TotalRows = LinkedRows + SkippedRows
   --   LinkedRows  = rows fully processed (fkLocationInventoryId is set)
   --   SkippedRows = rows that could not be processed (null fkProductId only;
   --                 null containers are resolved by STEP 0 and no longer a
   --                 skip reason)
   -- If the counts do not balance, there are rows with valid fkProductId and
   -- fkContainerId but no fkLocationInventoryId — check 1 and 3 above would
   -- have caught those cases.
   declare @TotalRows   int;
   declare @LinkedRows  int;
   declare @SkippedRows int;

   select
       @TotalRows   = count(*)
      ,@LinkedRows  = sum(case when tis.fkLocationInventoryId is not null then 1 else 0 end)
      -- SkippedRows: unlinked rows where the skip reason is a null fkProductId.
      -- Multiple ImportStaging rows per LocationInventory record (duplicates) are
      -- counted in @LinkedRows via fkLocationInventoryId, so they do not appear here.
      ,@SkippedRows = sum(case when tis.fkLocationInventoryId is null
                                and tis.fkProductId is null
                               then 1 else 0 end)
   from TabX.ImportStaging as tis;

   print concat('Post-run check 4 summary: '
               ,@TotalRows,   ' total row(s); '
               ,@LinkedRows,  ' fully linked (fkLocationInventoryId set); '
               ,@SkippedRows, ' skipped (null fkProductId).'
               ,case when @TotalRows = @LinkedRows + @SkippedRows
                     then ' OK — counts balance.'
                     else ' WARNING — counts do not balance; investigate.'
                end);


   COMMIT TRANSACTION;

END TRY
BEGIN CATCH
   ROLLBACK TRANSACTION;
   THROW;
END CATCH
GO







