-- s009_ArchiveAndPurgeImportStaging.sql
--
-- When     Who   What
-- 20260311 auto  Created: copy matched ImportStaging + ImportStagingAI rows to
--                their respective archive tables, then delete the source rows.
--
-- Purpose:
--   After the full posting pipeline (s005–s008) has been run and validated,
--   this script moves the processed rows out of the live staging tables:
--
--   STEP A — INSERT into TabX.ImportStagingArchive
--     Copies all ImportStaging rows that have a matching ImportStagingAI row
--     (joined on pkImportStagingId = fkImportStagingId).
--     RowVersionStamp is excluded: the archive table auto-generates a new value.
--
--   STEP B — INSERT into TabX.ImportStagingAIArchive
--     Copies all ImportStagingAI rows whose fkImportStagingId was archived in STEP A.
--     pkImportStagingAIId is excluded: the archive table has its own IDENTITY column.
--     fkImportStagingId is carried over so each AI row remains linked to its
--     corresponding ImportStagingArchive row.
--
--   STEP C — DELETE from TabX.ImportStagingAI
--     Removes the AI rows whose fkImportStagingId was archived.
--     Deleted before ImportStaging to satisfy the FK dependency order.
--
--   STEP D — DELETE from TabX.ImportStaging
--     Removes the staging rows archived in STEP A.
--
-- Prerequisites:
--   - s000_AlterArchiveTables.sql must have been run first (adds missing columns).
--   - s005 through s008 should be complete and validated before archiving.
--
-- Run order: AFTER s008_InsertAndLinkInventoryFromImportStaging.sql.
--
-- Safety:
--   All four steps run inside a single transaction. Any failure rolls back the
--   entire operation — no partial moves are left behind.
--   The PREVIEW section (SECTION 1) is always safe to run and shows exactly
--   what will be moved before any data is touched.
--
--use TabX
--GO


-- =========================================================================
-- SECTION 1: PREVIEW
-- Always safe to run. No data is modified.
-- Review this output before executing SECTION 2.
--
-- Returns three result sets:
--   Preview 1 — ImportStaging rows that will be archived (matched rows only)
--   Preview 2 — ImportStagingAI rows that will be archived
--   Preview 3 — ImportStaging rows NOT archived (no matching AI row; left behind)
-- =========================================================================

-- -----------------------------------------------------------------------
-- Preview 1: ImportStaging rows that will be archived
-- -----------------------------------------------------------------------
select
    tis.pkImportStagingId
   ,tis.fkLocationId
   ,tis.fkProductId
   ,tis.fkContainerId
   ,tis.fkInventoryId
   ,tis.fkLocationInventoryId
   ,tis.IsNewProduct
   ,tis.IsNewProductAlias
   ,tis.NewProductName
   ,tis.NewProductBrand
   ,tis.TabDetailDescription
   ,tis.DateCreated
   ,tis.DateModified
from TabX.ImportStaging as tis
inner join TabX.ImportStagingAI as isai
   on isai.fkImportStagingId = tis.pkImportStagingId
order by tis.fkLocationId, tis.pkImportStagingId;
GO


-- -----------------------------------------------------------------------
-- Preview 2: ImportStagingAI rows that will be archived
-- -----------------------------------------------------------------------
select
    isai.pkImportStagingAIId
   ,isai.fkImportStagingId
   ,isai.ItemAsListed
   ,isai.Brand
   ,isai.BrandNameShort
   ,isai.ProductName
   ,isai.ProductKeywords
   ,isai.ProductType
   ,isai.ProductCategory
   ,isai.IsWellKnownMixedDrink
   ,isai.ContainerSizeQty
   ,isai.ContainerSizeUnit
   ,isai.ContainerType
   ,isai.ABV
   ,isai.Country
   ,isai.City
   ,isai.StateProv
from TabX.ImportStagingAI as isai
inner join TabX.ImportStaging as tis
   on tis.pkImportStagingId = isai.fkImportStagingId
order by isai.fkImportStagingId, isai.pkImportStagingAIId;
GO


-- -----------------------------------------------------------------------
-- Preview 3: ImportStaging rows that will NOT be archived
-- These have no matching ImportStagingAI row and will be left in place.
-- Investigate whether AI processing was skipped for these rows.
-- -----------------------------------------------------------------------
select
    tis.pkImportStagingId
   ,tis.fkLocationId
   ,tis.fkProductId
   ,tis.fkContainerId
   ,tis.TabDetailDescription
   ,tis.DateCreated
   ,'No matching ImportStagingAI row' as Reason
from TabX.ImportStaging as tis
where not exists (
    select 1
    from TabX.ImportStagingAI as isai
    where isai.fkImportStagingId = tis.pkImportStagingId
)
order by tis.fkLocationId, tis.pkImportStagingId;
GO


-- =========================================================================
-- SECTION 2: ARCHIVE and PURGE
--
-- Review SECTION 1 output before running this block.
-- All four steps run inside a single transaction: if any step fails the
-- entire batch is rolled back automatically — no partial moves are left behind.
-- =========================================================================
BEGIN TRANSACTION;
BEGIN TRY

   -- -----------------------------------------------------------------------
   -- Capture the set of ImportStaging IDs to be archived.
   -- Only rows that have at least one matching ImportStagingAI row are included.
   -- -----------------------------------------------------------------------
   declare @ArchivedIds table (pkImportStagingId int not null primary key);

   insert into @ArchivedIds (pkImportStagingId)
   select distinct tis.pkImportStagingId
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId;

   declare @StagingCount int = @@rowcount;

   declare @ExpectedAICount int;
   select @ExpectedAICount = count(*)
   from TabX.ImportStagingAI as isai
   inner join @ArchivedIds as ids
      on ids.pkImportStagingId = isai.fkImportStagingId;

   print concat('Matched rows to archive: ', @StagingCount, ' ImportStaging row(s), ',
                @ExpectedAICount, ' ImportStagingAI row(s).');

   if @StagingCount = 0
      throw 50005,
            'No rows matched for archiving — ImportStaging has no rows with a matching ImportStagingAI row. Nothing archived or deleted.',
            1;


   -- -----------------------------------------------------------------------
   -- STEP A: INSERT into TabX.ImportStagingArchive
   -- RowVersionStamp is intentionally omitted — the archive table
   -- auto-generates a new timestamp value on insert.
   -- -----------------------------------------------------------------------
   insert into TabX.ImportStagingArchive
          (pkImportStagingId
          ,fkLocationId
          ,ExternalMenuId
          ,TabDetailDescription
          ,fkProductId
          ,fkContainerId
          ,fkCreatedByUserId
          ,DateCreated
          ,fkModifiedByUserId
          ,DateModified
          ,QtyOrdered
          ,fkInventoryId
          ,fkLocationInventoryId
          ,LastSold
          ,MinPrice
          ,MaxPrice
          ,NewProductName
          ,IsNewProduct
          ,IsNewProductAlias
          ,fkProductTypeId
          ,fkProductCategoryId
          ,fkNewProductBrandId
          ,NewProductBrand
          )
   select
       tis.pkImportStagingId
      ,tis.fkLocationId
      ,tis.ExternalMenuId
      ,tis.TabDetailDescription
      ,tis.fkProductId
      ,tis.fkContainerId
      ,tis.fkCreatedByUserId
      ,tis.DateCreated
      ,tis.fkModifiedByUserId
      ,tis.DateModified
      ,tis.QtyOrdered
      ,tis.fkInventoryId
      ,tis.fkLocationInventoryId
      ,tis.LastSold
      ,tis.MinPrice
      ,tis.MaxPrice
      ,tis.NewProductName
      ,tis.IsNewProduct
      ,tis.IsNewProductAlias
      ,tis.fkProductTypeId
      ,tis.fkProductCategoryId
      ,tis.fkNewProductBrandId
      ,tis.NewProductBrand
   from TabX.ImportStaging as tis
   inner join @ArchivedIds as ids
      on ids.pkImportStagingId = tis.pkImportStagingId;

   declare @StepAInserted int = @@rowcount;
   print concat('Step A: ', @StepAInserted, ' row(s) inserted into TabX.ImportStagingArchive.');


   -- -----------------------------------------------------------------------
   -- STEP B: INSERT into TabX.ImportStagingAIArchive
   -- pkImportStagingAIId is intentionally omitted — the archive table has
   -- its own IDENTITY column and generates new values on insert.
   -- fkImportStagingId is included so archive rows remain joinable.
   -- -----------------------------------------------------------------------
   insert into TabX.ImportStagingAIArchive
          (fkImportStagingId
          ,ItemAsListed
          ,Brand
          ,BrandNameShort
          ,ProductName
          ,ProductKeywords
          ,ContainerSizeQty
          ,ContainerSizeUnit
          ,ContainerType
          ,ABV
          ,ProductType
          ,ProductCategory
          ,IsWellKnownMixedDrink
          ,Country
          ,City
          ,StateProv
          )
   select
       isai.fkImportStagingId
      ,isai.ItemAsListed
      ,isai.Brand
      ,isai.BrandNameShort
      ,isai.ProductName
      ,isai.ProductKeywords
      ,isai.ContainerSizeQty
      ,isai.ContainerSizeUnit
      ,isai.ContainerType
      ,isai.ABV
      ,isai.ProductType
      ,isai.ProductCategory
      ,isai.IsWellKnownMixedDrink
      ,isai.Country
      ,isai.City
      ,isai.StateProv
   from TabX.ImportStagingAI as isai
   inner join @ArchivedIds as ids
      on ids.pkImportStagingId = isai.fkImportStagingId;

   declare @StepBInserted int = @@rowcount;
   print concat('Step B: ', @StepBInserted, ' row(s) inserted into TabX.ImportStagingAIArchive.');


   -- -----------------------------------------------------------------------
   -- PRE-DELETE VERIFICATION
   -- @@ROWCOUNT from each INSERT is the authoritative count — it reflects
   -- exactly what this transaction inserted and cannot be inflated by rows
   -- from prior runs. Any failure here throws and triggers ROLLBACK so no
   -- rows are deleted.
   -- -----------------------------------------------------------------------

   -- Verify Step A: insert count must match expected staging count.
   if @StepAInserted <> @StagingCount
      throw 50001,
            'Pre-delete check failed: ImportStagingArchive insert count does not match expected staging count. No rows deleted.',
            1;

   print concat('Pre-delete check A: OK — ', @StepAInserted,
                ' row(s) inserted into TabX.ImportStagingArchive.');

   -- Verify Step B: insert count must match expected AI count.
   if @StepBInserted <> @ExpectedAICount
      throw 50003,
            'Pre-delete check failed: ImportStagingAIArchive insert count does not match expected AI count. No rows deleted.',
            1;

   print concat('Pre-delete check B: OK — ', @StepBInserted,
                ' row(s) inserted into TabX.ImportStagingAIArchive.');


   -- -----------------------------------------------------------------------
   -- STEP C: DELETE from TabX.ImportStagingAI
   -- Deleted before ImportStaging to satisfy FK dependency order.
   -- -----------------------------------------------------------------------
   delete isai
   from TabX.ImportStagingAI as isai
   inner join @ArchivedIds as ids
      on ids.pkImportStagingId = isai.fkImportStagingId;

   declare @StepCDeleted int = @@rowcount;
   print concat('Step C: ', @StepCDeleted, ' row(s) deleted from TabX.ImportStagingAI.');


   -- -----------------------------------------------------------------------
   -- STEP D: DELETE from TabX.ImportStaging
   -- -----------------------------------------------------------------------
   delete tis
   from TabX.ImportStaging as tis
   inner join @ArchivedIds as ids
      on ids.pkImportStagingId = tis.pkImportStagingId;

   declare @StepDDeleted int = @@rowcount;
   print concat('Step D: ', @StepDDeleted, ' row(s) deleted from TabX.ImportStaging.');


   -- -----------------------------------------------------------------------
   -- Post-delete consistency checks
   -- All mismatches throw so the transaction rolls back rather than committing
   -- silently inconsistent state.
   -- -----------------------------------------------------------------------

   -- Check 2: ImportStaging delete count must match archive insert count.
   if @StepDDeleted <> @StepAInserted
      throw 50006,
            'Post-delete check failed: ImportStaging delete count does not match archive insert count.',
            1;
   print 'Post-delete check 2: OK — ImportStaging delete count matches archive insert count.';

   -- Check 3: ImportStagingAI delete count must match AI archive insert count.
   if @StepCDeleted <> @StepBInserted
      throw 50007,
            'Post-delete check failed: ImportStagingAI delete count does not match AI archive insert count.',
            1;
   print 'Post-delete check 3: OK — ImportStagingAI delete count matches AI archive insert count.';

   -- Check 4: No archived IDs should remain in ImportStaging.
   declare @LeftoverStaging int;
   select @LeftoverStaging = count(*)
   from TabX.ImportStaging as tis
   inner join @ArchivedIds as ids
      on ids.pkImportStagingId = tis.pkImportStagingId;

   if @LeftoverStaging > 0
      throw 50008,
            'Post-delete check failed: archived IDs still found in TabX.ImportStaging after delete.',
            1;
   print 'Post-delete check 4: OK — no archived IDs remain in TabX.ImportStaging.';

   -- Check 5: No archived IDs should remain in ImportStagingAI.
   declare @LeftoverAI int;
   select @LeftoverAI = count(*)
   from TabX.ImportStagingAI as isai
   inner join @ArchivedIds as ids
      on ids.pkImportStagingId = isai.fkImportStagingId;

   if @LeftoverAI > 0
      throw 50009,
            'Post-delete check failed: archived fkImportStagingIds still found in TabX.ImportStagingAI after delete.',
            1;
   print 'Post-delete check 5: OK — no archived IDs remain in TabX.ImportStagingAI.';


   COMMIT TRANSACTION;
   print concat('Done. Archived and purged ', @StagingCount, ' ImportStaging row(s) and ',
                @StepBInserted, ' ImportStagingAI row(s).');

END TRY
BEGIN CATCH
   ROLLBACK TRANSACTION;
   THROW;
END CATCH
GO
