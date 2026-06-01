-- s007_InsertNewProductAliasesFromImportStaging.sql
--
-- When     Who   What
-- 20260309 auto  Created: insert product aliases identified by the AI classification pipeline.
--
-- Purpose:
--   Insert records into Common.ProductAliases for products where the AI classification
--   pipeline (updateTisFromAI.sql) matched an existing product but under a different name
--   (IsNewProductAlias=1). Registering the alternate name as an alias ensures future AI
--   runs resolve these items directly without generating another IsNewProductAlias row.
--
-- Run order: AFTER s006_InsertNewProductsFromImportStaging.sql, BEFORE s010.
--   s006 must run first so that any new products inserted by that script are available
--   as alias targets here (edge case: a product was new in this batch and an alias was
--   also detected for it in the same batch).
--
-- Candidate rows are identified by:
--   ImportStaging.IsNewProductAlias = 1     (AI matched a product under a different name)
--   ImportStaging.IsNewProduct      <> 1    (new-product rows are not aliased)
--   ImportStaging.fkProductId      IS NOT NULL  (the matched product FK is required)
--   A matching ImportStagingAI row exists (INNER JOIN — rows with no AI record are excluded)
--   ImportStagingAI.ProductName    IS NOT NULL and NOT empty  (alias text source)
--   ImportStagingAI.ProductName (truncated to 100) does NOT case-insensitively match
--     Common.Products.ProductName for the resolved product  (alias would be redundant)
--
-- Rows where no ImportStagingAI record exists are excluded from all inserts and are
-- surfaced separately by post-run check 2 for manual investigation.
--
-- Mixed drinks (fkProductTypeId = 4):
--   Mixed drink rows with IsNewProductAlias=1 are included naturally — there is no
--   type filter. The alias is registered against fkProductId, which was set by the AI
--   pipeline to the matched product. The brand of that product (expected to be the
--   generic 'Mixed Drink' brand after s006 runs) is not referenced here; ProductAliases
--   has no brand column.
--
-- Alias text:
--   The alias is taken from ImportStagingAI.ProductName — the name the AI inferred from
--   the venue's menu, which differs from Common.Products.ProductName. This is the
--   "street name" that needs to be catalogued so future lookups succeed without review.
--   ImportStagingAI.ProductName is varchar(255); Common.ProductAliases.ProductAlias is
--   varchar(100). Names longer than 100 characters are truncated. The SECTION 1 preview
--   flags any truncation for reviewer attention.
--
-- Safety filter:
--   Aliases where left(isai.ProductName, 100) exactly matches Common.Products.ProductName
--   (case-insensitive) are excluded — they add no value and may indicate an AI quirk.
--
-- Deduplication within batch:
--   Multiple ImportStaging rows can produce the same (ProductAlias, fkProductId) pair.
--   These are collapsed to one candidate row before inserting.
--
-- Deduplication against Common.ProductAliases:
--   Checks lower(trim(ProductAlias)) + fkProductId. If a matching alias already exists
--   for this product, the row is skipped.
--   Also checks Common.Products.ProductName: if the alias text matches the canonical
--   product name exactly (case-insensitive), the row is skipped (alias not needed).
--
-- Re-run safety:
--   There is no FK column in ImportStaging to backfill after inserting aliases (unlike
--   s005/s006). Idempotency is guaranteed solely by the NOT EXISTS dedup against
--   Common.ProductAliases. Re-running this script is always safe.
--
-- FK note on fkCreatedByUserId / fkModifiedByUserId:
--   The original Common.ProductAliases schema references Security.Users for these columns.
--   fix_schema_002 corrects them to TabX.Users. User ID 1 is used here; verify it exists
--   in whichever table is currently referenced by the FK constraint before running.
--
--use TabX
--GO


-- =========================================================================
-- SECTION 1: PREVIEW
-- Always safe to run. No data is modified.
-- Review this output before executing SECTION 2.
--
-- Key columns:
--   CandidateAlias         the alias text that would be inserted (truncated to 100 chars)
--   IsTruncated            1 if the alias was truncated from the original AI product name;
--                          review whether the truncated form is still meaningful
--   OriginalAIProductName  full text of ImportStagingAI.ProductName before truncation
--   fkProductId            the product this alias will be linked to
--   CanonicalProductName   Common.Products.ProductName for that product (for comparison)
--   SourceRowCount         number of ImportStaging rows generating this (alias, product) pair
--   SampleItems            example TabDetailDescriptions for context
--   InsertStatus           whether this candidate will be inserted or skipped
-- =========================================================================
; with

-- Identify candidate rows: IsNewProductAlias=1 with a resolved product and alias text.
source_rows as (
   select
      tis.pkImportStagingId
     ,tis.fkProductId
     ,tis.TabDetailDescription
     ,tis.DateCreated
     -- Alias text: AI-inferred product name, truncated to ProductAlias column width (100).
     ,left(nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), ''), 100)
         as AliasText
     -- Preserve full text for truncation detection in SECTION 1.
     ,nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '')
         as FullAIProductName
     ,row_number() over (
          partition by lower(trim(
              left(nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), ''), 100)
              collate SQL_Latin1_General_Cp1251_CS_AS
          ))
                     ,tis.fkProductId
          order by tis.pkImportStagingId
      ) as rn
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProductAlias = 1
     and coalesce(tis.IsNewProduct, 0) <> 1    -- new-product rows are not aliased
     and tis.fkProductId       is not null
     and tis.fkProductId       <> 1    -- fkProductId=1 is the 'Undefined' product; no aliases
     and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null
),

-- Deduplicate to one candidate per unique (AliasText, fkProductId).
deduped as (
   select
      lower(trim(AliasText collate SQL_Latin1_General_Cp1251_CS_AS))   as AliasKey
     ,max(AliasText)           as CandidateAlias
     ,max(FullAIProductName)   as OriginalAIProductName
     ,fkProductId
     ,min(DateCreated)         as EarliestImport
     ,count(*)                 as SourceRowCount
     ,string_agg(case when rn <= 3 then left(TabDetailDescription, 60) end, ' | ')
         within group (order by pkImportStagingId)   as SampleItems
   from source_rows
   where AliasText is not null
   group by lower(trim(AliasText collate SQL_Latin1_General_Cp1251_CS_AS))
           ,fkProductId
)

select
    d.CandidateAlias
   ,case
       when len(d.OriginalAIProductName) > 100 then 1
       else 0
    end                                          as IsTruncated
   ,d.OriginalAIProductName
   ,d.fkProductId
   ,(
      select top 1 p.ProductName
      from Common.Products as p
      where p.pkProductId = d.fkProductId
   )                                             as CanonicalProductName
   ,d.EarliestImport
   ,d.SourceRowCount
   ,d.SampleItems
   ,case
       -- Alias text matches canonical product name — no alias needed.
       when exists (
           select 1 from Common.Products as p
           where p.pkProductId          = d.fkProductId
             and lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) = d.AliasKey
       ) then 'Matches canonical name — will be skipped'
       -- Alias already registered for this product.
       when exists (
           select 1 from Common.ProductAliases as pa
           where pa.fkProductId               = d.fkProductId
             and lower(trim(pa.ProductAlias collate SQL_Latin1_General_Cp1251_CS_AS)) = d.AliasKey
       ) then 'Already in Common.ProductAliases — will be skipped'
       -- Alias text exists in ProductAliases but linked to a different product.
       when exists (
           select 1 from Common.ProductAliases as pa
           where lower(trim(pa.ProductAlias collate SQL_Latin1_General_Cp1251_CS_AS)) = d.AliasKey
             and pa.fkProductId              <> d.fkProductId
       ) then 'Alias text exists for a DIFFERENT product — review before inserting'
       else 'NEW — will be inserted'
   end                                           as InsertStatus
from deduped as d
order by CanonicalProductName, d.CandidateAlias;
GO

/*

-- =========================================================================
-- SECTION 2: INSERT new product aliases into Common.ProductAliases
--
-- Review SECTION 1 output before running this block.
-- There is no UPDATE step (no FK to backfill in ImportStaging for aliases).
-- =========================================================================
BEGIN TRANSACTION;
BEGIN TRY

   -- -----------------------------------------------------------------------
   -- SECTION 2: Insert new aliases into Common.ProductAliases
   -- Skips aliases that:
   --   (a) already exist for the same product (exact case-insensitive match), or
   --   (b) exactly match the canonical Common.Products.ProductName (no alias needed).
   -- Does NOT skip aliases that exist for a different product — those are flagged
   -- in SECTION 1 as 'review before inserting' and will still be inserted here,
   -- since the same short name can legitimately alias two different products.
   -- -----------------------------------------------------------------------
   ; with

   source_rows as (
      select
         tis.pkImportStagingId
        ,tis.fkProductId
        ,tis.DateCreated
        ,left(nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), ''), 100)
            as AliasText
      from TabX.ImportStaging as tis
      inner join TabX.ImportStagingAI as isai
         on isai.fkImportStagingId = tis.pkImportStagingId
      where tis.IsNewProductAlias = 1
        and coalesce(tis.IsNewProduct, 0) <> 1    -- new-product rows are not aliased
        and tis.fkProductId       is not null
        and tis.fkProductId       <> 1    -- fkProductId=1 is the 'Undefined' product; no aliases
        and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null
   ),

   deduped as (
      select
         lower(trim(AliasText collate SQL_Latin1_General_Cp1251_CS_AS))   as AliasKey
        ,max(AliasText)    as AliasText
        ,fkProductId
        ,min(DateCreated)  as DateCreated
      from source_rows
      where AliasText is not null
      group by lower(trim(AliasText collate SQL_Latin1_General_Cp1251_CS_AS))
              ,fkProductId
   ),

   new_aliases as (
      select d.*
      from deduped as d
      -- Skip if this alias already exists for this product.
      where not exists (
          select 1 from Common.ProductAliases as pa
          where pa.fkProductId               = d.fkProductId
            and lower(trim(pa.ProductAlias collate SQL_Latin1_General_Cp1251_CS_AS)) = d.AliasKey
      )
      -- Skip if the alias text exactly matches the canonical product name.
      and not exists (
          select 1 from Common.Products as p
          where p.pkProductId            = d.fkProductId
            and lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) = d.AliasKey
      )
   )

   insert into Common.ProductAliases
          (fkProductId
          ,ProductAlias
          ,IsActive
          ,fkCreatedByUserId   -- FK references Security.Users (original) or TabX.Users (after fix_schema_002)
          ,DateCreated
          ,fkModifiedByUserId
          ,DateModified
          )
   select
       fkProductId
      ,AliasText
      ,1                   as IsActive
      ,1                   as fkCreatedByUserId
      ,DateCreated
      ,1                   as fkModifiedByUserId
      ,getdate()           as DateModified
   from new_aliases;

   declare @AliasesInserted int = @@rowcount;
   print concat('Section 2: ', @AliasesInserted, ' new alias(es) inserted into Common.ProductAliases.');


   -- -----------------------------------------------------------------------
   -- Post-run checks
   -- -----------------------------------------------------------------------

   -- Check 1: IsNewProductAlias=1 rows whose alias is still absent from
   -- Common.ProductAliases after this run. Excludes rows where the alias
   -- matches the canonical product name (those are intentionally skipped).
   -- This should be 0 after a successful run.
   declare @StillUnresolved int;
   select @StillUnresolved = count(*)
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProductAlias = 1
     and coalesce(tis.IsNewProduct, 0) <> 1    -- new-product rows intentionally excluded
     and tis.fkProductId       is not null
     and tis.fkProductId       <> 1    -- fkProductId=1 is the 'Undefined' product; no aliases
     and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null
     and not exists (
         select 1 from Common.ProductAliases as pa
         where pa.fkProductId               = tis.fkProductId
           and lower(trim(pa.ProductAlias collate SQL_Latin1_General_Cp1251_CS_AS)) = lower(trim(
               left(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS, 100)
           ))
     )
     -- Exclude intentional skips: alias equals canonical product name.
     and not exists (
         select 1 from Common.Products as p
         where p.pkProductId              = tis.fkProductId
           and lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) = lower(trim(
               left(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS, 100)
           ))
     );

   if @StillUnresolved > 0
      print concat('WARNING: ', @StillUnresolved,
                   ' IsNewProductAlias=1 row(s) still have no matching entry in ',
                   'Common.ProductAliases after this run. Run the SECTION 1 preview ',
                   'to investigate.');
   else
      print 'Post-run check 1: OK — all resolvable aliases are now registered.';

   -- Check 2: IsNewProductAlias=1 rows with no ImportStagingAI record or null ProductName.
   -- These were excluded from the INSERT (INNER JOIN requirement) and require manual
   -- investigation. LEFT OUTER JOIN here is intentional — it is precisely the rows
   -- that failed the inner join that this check needs to surface.
   declare @MissingAliasSource int;
   select @MissingAliasSource = count(*)
   from TabX.ImportStaging as tis
   left outer join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProductAlias = 1
     and coalesce(tis.IsNewProduct, 0) <> 1    -- mirror INSERT filter; exclude intentionally skipped rows
     and tis.fkProductId       is not null
     and tis.fkProductId       <> 1    -- mirror INSERT filter; Undefined product excluded
     and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is null;

   if @MissingAliasSource > 0
      print concat('WARNING: ', @MissingAliasSource,
                   ' IsNewProductAlias=1 row(s) were skipped because ImportStagingAI.ProductName ',
                   'is NULL or empty. Investigate the AI output for these ImportStaging rows.');
   else
      print 'Post-run check 2: OK — no rows missing alias source text.';


   COMMIT TRANSACTION;

END TRY
BEGIN CATCH
   ROLLBACK TRANSACTION;
   THROW;
END CATCH
GO

*/
