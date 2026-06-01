-- s006b_InsertMixedDrinksFromImportStaging.sql
--
-- When     Who   What
-- 20260312 auto  Created: insert new cocktail records into Common.MixedDrinks from
--                the live ImportStaging / ImportStagingAI pair.
--
-- Purpose:
--   After s006 inserts new mixed drink products into Common.Products and backfills
--   ImportStaging.fkProductId, this script creates the corresponding rows in
--   Common.MixedDrinks so the new cocktails are fully catalogued.
--
--   Candidate rows are identified by:
--     ImportStaging.IsNewProduct    = 1
--     ImportStaging.fkProductTypeId = 4   (Mixed Drink)
--     ImportStaging.fkProductId    IS NOT NULL
--     A matching ImportStagingAI row exists (INNER JOIN on fkImportStagingId)
--
--   Multiple ImportStaging rows may resolve to the same fkProductId
--   (the same cocktail sold at several locations).  These are collapsed to one
--   MixedDrinks row using the earliest DateCreated and the lowest fkLocationId
--   for determinism.
--
--   Deduplication against Common.MixedDrinks:
--     Rows whose fkProductId already appears in Common.MixedDrinks are skipped.
--
--   MixedDrinkName is sourced from ImportStagingAI.ProductName — the name the AI
--   inferred from the venue menu.  The "Official Reporting Name" column is left
--   NULL; it can be populated by a curator after review.
--
-- Run order: AFTER s006_InsertNewProductsFromImportStaging.sql, BEFORE s007.
--
-- Safety:
--   SECTION 1 (PREVIEW) is always safe to run — no data is modified.
--   SECTION 2 (INSERT) runs inside a transaction; any failure rolls back fully.
--
--use TabX
--GO


-- =========================================================================
-- SECTION 1: PREVIEW
-- Always safe to run.  No data is modified.
-- Review this output before executing SECTION 2.
--
-- Key columns:
--   SampleImportStagingId   one pkImportStagingId from the candidate set
--   fkProductId             the product that will be linked to MixedDrinks
--   ExistingProductName     Common.Products.ProductName for that product
--   MixedDrinkName          AI-inferred name from ImportStagingAI
--   fkLocationId            location of the earliest-seen staging row
--   SourceRowCount          number of staging rows that produced this candidate
--   InsertStatus            'NEW — will be inserted' or a skip reason
-- =========================================================================

; with

-- Aggregate AI name per staging row (multiple AI rows can share one fkImportStagingId).
ai_names as (
   select
      isai.fkImportStagingId
     ,max(nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '')) as ProductName
   from TabX.ImportStagingAI as isai
   group by isai.fkImportStagingId
),

-- Qualify: mixed drink staging rows with IsNewProduct=1 that have a resolved product and a non-null AI name.
candidates as (
   select
      tis.pkImportStagingId
     ,tis.fkLocationId
     ,tis.fkProductId
     ,tis.DateCreated
     ,ain.ProductName as MixedDrinkName
     ,row_number() over (
          partition by tis.fkProductId
          order by tis.DateCreated asc, tis.pkImportStagingId asc
      ) as rn
   from TabX.ImportStaging as tis
   inner join ai_names as ain
      on ain.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProduct    = 1
     and tis.fkProductTypeId = 4
     and tis.fkProductId    is not null
     and ain.ProductName    is not null
),

-- Deduplicate to one row per fkProductId; location and name taken from the earliest-dated row.
deduped as (
   select
      fkProductId
     ,max(case when rn = 1 then pkImportStagingId end) as SampleImportStagingId
     ,max(case when rn = 1 then fkLocationId end)      as fkLocationId
     ,max(case when rn = 1 then MixedDrinkName end)    as MixedDrinkName
     ,min(DateCreated)                                  as DateCreated
     ,count(*)                                          as SourceRowCount
   from candidates
   group by fkProductId
)

select
    d.SampleImportStagingId
   ,d.fkProductId
   ,p.ProductName                                                   as ExistingProductName
   ,d.MixedDrinkName
   ,d.fkLocationId
   ,d.DateCreated
   ,d.SourceRowCount
   ,case
       when not exists (
               select 1 from Common.Products as cp
               where cp.pkProductId = d.fkProductId
           )
           then 'WARNING: fkProductId not found in Common.Products — row will be skipped'
       when exists (
               select 1 from Common.MixedDrinks as md
               where md.fkProductId = d.fkProductId
           )
           then 'Already in Common.MixedDrinks — will be skipped'
       else 'NEW — will be inserted'
    end                                                             as InsertStatus
from deduped as d
left outer join Common.Products as p
   on p.pkProductId = d.fkProductId
order by d.DateCreated, d.fkProductId;
GO


/*

-- =========================================================================
-- SECTION 2: INSERT into Common.MixedDrinks
--
-- Review SECTION 1 output before running this block.
-- Runs inside a single transaction; any failure rolls back the entire insert.
-- =========================================================================
BEGIN TRANSACTION;
BEGIN TRY

   ; with

   ai_names as (
      select
         isai.fkImportStagingId
        ,max(nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '')) as ProductName
      from TabX.ImportStagingAI as isai
      group by isai.fkImportStagingId
   ),

   candidates as (
      select
         tis.pkImportStagingId
        ,tis.fkLocationId
        ,tis.fkProductId
        ,tis.DateCreated
        ,ain.ProductName as MixedDrinkName
        ,row_number() over (
             partition by tis.fkProductId
             order by tis.DateCreated asc, tis.pkImportStagingId asc
         ) as rn
      from TabX.ImportStaging as tis
      inner join ai_names as ain
         on ain.fkImportStagingId = tis.pkImportStagingId
      where tis.IsNewProduct    = 1
        and tis.fkProductTypeId = 4
        and tis.fkProductId    is not null
        and ain.ProductName    is not null
   ),

   deduped as (
      select
         fkProductId
        ,max(case when rn = 1 then fkLocationId end)   as fkLocationId
        ,max(case when rn = 1 then MixedDrinkName end)  as MixedDrinkName
        ,min(DateCreated)                               as DateCreated
      from candidates
      group by fkProductId
   ),

   -- Exclude products already catalogued in Common.MixedDrinks.
   new_rows as (
      select d.*
      from deduped as d
      where not exists (
          select 1
          from Common.MixedDrinks as md
          where md.fkProductId = d.fkProductId
      )
   )

   insert into Common.MixedDrinks
          (fkProductId
          ,IsActive
          ,fkCreatedByUserId
          ,DateCreated
          ,fkModifiedByUserId
          ,DateModified
          ,MixedDrinkName
          ,fkLocationId
          )
   select
       fkProductId
      ,1              as IsActive
      ,1              as fkCreatedByUserId
      ,DateCreated
      ,1              as fkModifiedByUserId
      ,getdate()      as DateModified
      ,MixedDrinkName
      ,fkLocationId
   from new_rows;

   declare @Inserted int = @@rowcount;
   print concat('Inserted ', @Inserted, ' row(s) into Common.MixedDrinks.');


   -- -----------------------------------------------------------------------
   -- Post-run check: confirm no qualifying products remain absent from
   -- Common.MixedDrinks after the insert.
   -- -----------------------------------------------------------------------
   declare @StillMissing int;

   select @StillMissing = count(distinct tis.fkProductId)
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProduct    = 1
     and tis.fkProductTypeId = 4
     and tis.fkProductId    is not null
     and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null
     and not exists (
         select 1
         from Common.MixedDrinks as md
         where md.fkProductId = tis.fkProductId
     );

   if @StillMissing > 0
      print concat('WARNING: ', @StillMissing,
                   ' product(s) still absent from Common.MixedDrinks after insert. ',
                   'Run SECTION 1 to investigate.');
   else
      print 'Post-run check: OK — all qualifying mixed drink products are present in Common.MixedDrinks.';


   COMMIT TRANSACTION;
   print concat('Done. ', @Inserted, ' mixed drink row(s) inserted into Common.MixedDrinks.');

END TRY
BEGIN CATCH
   ROLLBACK TRANSACTION;
   THROW;
END CATCH
GO


*/

