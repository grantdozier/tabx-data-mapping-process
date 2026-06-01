--USE TabX
--GO

-- Purpose: Update fkNewProductBrandId in TabX.ImportStaging to reflect brands
-- resolved during the brand posting process (s0300/s0350).
-- Targets rows where fkNewProductBrandId was NULL because the brand did not
-- yet exist at AI mapping time.
--
-- Three cases handled:
--   1. IsNewBrand = 1              : brand was inserted by s0300; resolve via BrandDescription join
--   2. IsInsertBrandAlias = 1
--      AND fkBrandIdExisting IS NULL  : alias for a newly inserted brand; resolve via BrandDescription join
--   3. IsInsertBrandAlias = 1
--      AND fkBrandIdExisting IS NOT NULL : alias for a pre-existing brand; use fkBrandIdExisting directly
--
-- Verification: run the SELECT preview below before and after to confirm rows affected

-- Preview: shows all rows that will be updated by each of the three cases
SELECT tis.pkImportStagingId
      ,tis.TabDetailDescription
      ,tis.NewProductBrand
      ,tis.fkNewProductBrandId
      ,tisb.IsNewBrand
      ,tisb.IsInsertBrandAlias
      ,tisb.fkBrandIdExisting
      ,coalesce(cb.pkBrandId, tisb.fkBrandIdExisting) AS ResolvedBrandId
      ,coalesce(cb.BrandDescription, cast(tisb.fkBrandIdExisting as varchar)) AS ResolvedBrandDescription
      ,case
          when tisb.IsNewBrand = 1 then 'Case 1: new brand'
          when tisb.IsInsertBrandAlias = 1 and tisb.fkBrandIdExisting is null then 'Case 2: alias for new brand'
          when tisb.IsInsertBrandAlias = 1 and tisb.fkBrandIdExisting is not null then 'Case 3: alias for existing brand'
          else 'unmatched'
       end AS ResolvedBy
FROM TabX.ImportStaging AS tis
INNER JOIN TabX.ImportStagingBrands AS tisb
    ON tisb.TabDetailDescription = tis.TabDetailDescription
LEFT JOIN Common.Brands AS cb
    ON cb.BrandDescription = tisb.BrandDescription
    AND cb.IsActive = 1
WHERE tis.fkNewProductBrandId IS NULL
AND (
    tisb.IsNewBrand = 1
    OR (tisb.IsInsertBrandAlias = 1 and tisb.fkBrandIdExisting is null)
    OR (tisb.IsInsertBrandAlias = 1 and tisb.fkBrandIdExisting is not null)
)
ORDER BY tis.TabDetailDescription


/*

-- Case 1: Update fkNewProductBrandId for newly inserted brands (IsNewBrand = 1)
UPDATE tis
SET    tis.fkNewProductBrandId = nb.pkBrandId
FROM   TabX.ImportStaging AS tis
INNER JOIN (
    SELECT DISTINCT
        tisb.TabDetailDescription
       ,cb.pkBrandId
    FROM   TabX.ImportStagingBrands AS tisb
    INNER JOIN Common.Brands AS cb
        ON  cb.BrandDescription = tisb.BrandDescription
        AND cb.IsActive = 1
    WHERE  tisb.IsNewBrand = 1
) AS nb ON nb.TabDetailDescription = tis.TabDetailDescription
WHERE  tis.fkNewProductBrandId IS NULL

GO


-- Case 2: Update fkNewProductBrandId for brand-alias rows where the brand was
-- newly inserted by s0300 (IsInsertBrandAlias=1, fkBrandIdExisting was NULL,
-- meaning no pre-existing FK was on record at staging time)
UPDATE tis
SET    tis.fkNewProductBrandId = nb.pkBrandId
FROM   TabX.ImportStaging AS tis
INNER JOIN (
    SELECT DISTINCT
        tisb.TabDetailDescription
       ,cb.pkBrandId
    FROM   TabX.ImportStagingBrands AS tisb
    INNER JOIN Common.Brands AS cb
        ON  cb.BrandDescription = tisb.BrandDescription
        AND cb.IsActive = 1
    WHERE  tisb.IsInsertBrandAlias = 1
    AND    tisb.fkBrandIdExisting IS NULL
) AS nb ON nb.TabDetailDescription = tis.TabDetailDescription
WHERE  tis.fkNewProductBrandId IS NULL

GO


-- Case 3: Update fkNewProductBrandId for brand-alias rows where the brand
-- already existed at staging time (IsInsertBrandAlias=1, fkBrandIdExisting IS NOT NULL).
-- Use fkBrandIdExisting directly — no BrandDescription join needed.
UPDATE tis
SET    tis.fkNewProductBrandId = tisb.fkBrandIdExisting
FROM   TabX.ImportStaging AS tis
INNER JOIN TabX.ImportStagingBrands AS tisb
    ON  tisb.TabDetailDescription = tis.TabDetailDescription
WHERE  tisb.IsInsertBrandAlias = 1
AND    tisb.fkBrandIdExisting IS NOT NULL
AND    tis.fkNewProductBrandId IS NULL

GO

*/


-- Diagnostic: check why pkImportStagingId rows have no matching ImportStagingBrands record.
-- Uses lower(trim()) join to detect casing or whitespace mismatches vs. exact-match failures.
-- If the loose join finds a match but the strict join above does not, the issue is a
-- collation/whitespace difference in TabDetailDescription.
-- If neither finds a match, the item was never included in the brand posting batch.
SELECT
    tis.pkImportStagingId
   ,tis.TabDetailDescription          AS IS_TabDetailDescription
   ,tis.NewProductBrand
   ,tis.fkNewProductBrandId
   ,tisb.pkImportStagingBrandsId
   ,tisb.TabDetailDescription         AS ISB_TabDetailDescription
   ,tisb.Brand
   ,tisb.BrandDescription
   ,tisb.IsNewBrand
   ,tisb.IsInsertBrandAlias
   ,tisb.fkBrandIdExisting
FROM TabX.ImportStaging AS tis
LEFT JOIN TabX.ImportStagingBrands AS tisb
    ON lower(trim(tisb.TabDetailDescription)) = lower(trim(tis.TabDetailDescription))
WHERE tis.pkImportStagingId IN (24905, 25001)
