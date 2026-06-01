-- kwUpdateProductFromKeywords.sql
-- Keyword-based product match: preview then update ImportStaging.
--
-- WORKFLOW
--   1. Run the LOAD section to populate #kw_matches.
--   2. Run PART 1 (SELECT) to review proposed changes.
--   3. Run PART 2 (UPDATE) only after confirming Part 1 looks correct.
--
-- COLUMNS UPDATED
--   fkProductId         -- pkProductId of the keyword-matched product
--   fkNewProductBrandId -- pkBrandId of that product's brand (user-visible as "fkBrandId")
--
-- MATCH STRATEGY (same as kwMatchProducts.sql)
--   PRIMARY  : ProductKeywords tokens in Products.ProductName, scoped to brand
--              resolved from BrandKeywords.
--   FALLBACK : All keywords pooled against ProductName cross-brand.
--              Fires only when primary finds nothing (e.g. fkBrandId=NULL products
--              like 'Chartreuse Green' where brand name is part of product name).
--
-- Only rows with at least one keyword match are loaded into #kw_matches.
-- The UPDATE skips rows where fkProductId is already set; remove the
-- WHERE guard below if you want to overwrite existing assignments.
--
-- use TabX
-- GO

-- ============================================================
-- LOAD — populate #kw_matches
-- Re-run this section any time to refresh before Part 2.
-- ============================================================

if object_id('tempdb..#kw_matches') is not null drop table #kw_matches;
GO

;with

isai_dedup as (
   select
      fkImportStagingId
     ,ItemAsListed
     ,Brand
     ,ProductName
     ,ProductKeywords
     ,BrandKeywords
   from (
      select
         fkImportStagingId
        ,ItemAsListed
        ,Brand
        ,ProductName
        ,ProductKeywords
        ,BrandKeywords
        ,row_number() over (
            partition by fkImportStagingId
            order by pkImportStagingAIId desc
         ) as ai_rn
      from TabX.ImportStagingAI
   ) as ai_ranked
   where ai_rn = 1
),

brand_kw_scored as (
   select
      isai.fkImportStagingId
     ,b.pkBrandId
     ,b.BrandDescription
     ,count(distinct lower(trim(bkw.value collate SQL_Latin1_General_Cp1251_CS_AS))) as brand_kw_hits
   from isai_dedup as isai
   cross apply string_split(isai.BrandKeywords, '|') as bkw
   join Common.Brands as b
      on b.IsActive = 1
     and len(trim(bkw.value)) > 2
     and lower(b.BrandDescription) like '%' + replace(replace(replace(replace(
            lower(trim(bkw.value collate SQL_Latin1_General_Cp1251_CS_AS)),
            '\','\\'), '%','\%'), '_','\_'), '[','\[') + '%' escape '\'
   where isai.BrandKeywords is not null
   group by isai.fkImportStagingId, b.pkBrandId, b.BrandDescription
),

best_brand as (
   select fkImportStagingId, pkBrandId, BrandDescription, brand_kw_hits
   from (
      select *,
         row_number() over (
            partition by fkImportStagingId
            order by brand_kw_hits desc, len(BrandDescription) asc, pkBrandId asc
         ) as brand_rank
      from brand_kw_scored
   ) as ranked
   where brand_rank = 1
),

primary_kw as (
   select
      isai.fkImportStagingId
     ,p.pkProductId
     ,p.ProductName
     ,p.fkBrandId
     ,count(distinct lower(trim(pkw.value collate SQL_Latin1_General_Cp1251_CS_AS))) as kw_hits
   from isai_dedup as isai
   join best_brand as bb
      on bb.fkImportStagingId = isai.fkImportStagingId
   cross apply string_split(isai.ProductKeywords, '|') as pkw
   join Common.Products as p
      on p.fkBrandId = bb.pkBrandId
     and p.IsActive = 1
     and len(trim(pkw.value)) > 2
     and lower(p.ProductName) like '%' + replace(replace(replace(replace(
            lower(trim(pkw.value collate SQL_Latin1_General_Cp1251_CS_AS)),
            '\','\\'), '%','\%'), '_','\_'), '[','\[') + '%' escape '\'
   where isai.ProductKeywords is not null
   group by isai.fkImportStagingId, p.pkProductId, p.ProductName, p.fkBrandId
),

best_primary as (
   select fkImportStagingId, pkProductId, ProductName, fkBrandId, kw_hits
   from (
      select *,
         row_number() over (
            partition by fkImportStagingId
            order by kw_hits desc, len(ProductName) asc, pkProductId asc
         ) as rn
      from primary_kw
   ) as ranked
   where rn = 1
),

fallback_kw as (
   select
      isai.fkImportStagingId
     ,p.pkProductId
     ,p.ProductName
     ,p.fkBrandId
     ,count(distinct lower(all_kw.token)) as kw_hits
   from isai_dedup as isai
   left join best_primary as bpr
      on bpr.fkImportStagingId = isai.fkImportStagingId
   cross apply (
      select trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS) as token
      from string_split(
         isnull(isai.BrandKeywords, '') + '|' + isnull(isai.ProductKeywords, ''),
         '|'
      ) as kw
   ) as all_kw
   join Common.Products as p
      on p.IsActive = 1
     and p.fkBrandId is not null
     and len(all_kw.token) > 2
     and lower(p.ProductName) like '%' + replace(replace(replace(replace(
            lower(all_kw.token),
            '\','\\'), '%','\%'), '_','\_'), '[','\[') + '%' escape '\'
   where bpr.fkImportStagingId is null
     and isai.ProductKeywords is not null
   group by isai.fkImportStagingId, p.pkProductId, p.ProductName, p.fkBrandId
),

best_fallback as (
   select fkImportStagingId, pkProductId, ProductName, fkBrandId, kw_hits
   from (
      select *,
         row_number() over (
            partition by fkImportStagingId
            order by kw_hits desc, len(ProductName) asc, pkProductId asc
         ) as rn
      from fallback_kw
   ) as ranked
   where rn = 1
)

select
   tis.pkImportStagingId
  ,isai.ItemAsListed
  ,isai.Brand                                              as ai_Brand
  ,isai.ProductName                                        as ai_ProductName
  ,isai.ProductKeywords
  ,isai.BrandKeywords
  ,tis.fkProductId                                         as current_fkProductId
  ,tis.fkNewProductBrandId                                 as current_fkNewProductBrandId
  ,coalesce(bpr.pkProductId,  bfb.pkProductId)            as new_fkProductId
  ,coalesce(bpr.fkBrandId,    bfb.fkBrandId)              as new_fkNewProductBrandId
  ,coalesce(bpr.ProductName,  bfb.ProductName)            as matched_ProductName
  ,b.BrandDescription                                      as matched_BrandDescription
  ,coalesce(bpr.kw_hits,      bfb.kw_hits)                as kw_hits
  ,case
      when bpr.pkProductId is not null then 'brand-scoped'
      when bfb.pkProductId is not null then 'fallback'
   end                                                     as match_path
into #kw_matches
from TabX.ImportStaging as tis
join isai_dedup as isai
   on isai.fkImportStagingId = tis.pkImportStagingId
left join best_brand as bb
   on bb.fkImportStagingId = tis.pkImportStagingId
left join best_primary as bpr
   on bpr.fkImportStagingId = tis.pkImportStagingId
left join best_fallback as bfb
   on bfb.fkImportStagingId = tis.pkImportStagingId
left join Common.Brands as b
   on b.pkBrandId = coalesce(bpr.fkBrandId, bfb.fkBrandId)
where coalesce(bpr.pkProductId, bfb.pkProductId) is not null;

select
   count(*)                                                               as rows_matched
  ,sum(case when current_fkProductId is null     then 1 else 0 end)     as rows_eligible_for_update
  ,sum(case when current_fkProductId is not null then 1 else 0 end)     as rows_skipped_by_part2_guard
from #kw_matches;
GO

-- ============================================================
-- PART 1 — PREVIEW
-- Review all proposed changes before running Part 2.
-- Pay attention to:
--   match_path='fallback' rows — cross-brand matches are less precise.
--   current_fkProductId IS NOT NULL rows — these will be SKIPPED by Part 2
--   (the WHERE tis.fkProductId IS NULL guard in Part 2 protects them).
--   Remove that guard to overwrite existing assignments.
-- ============================================================

select
   pkImportStagingId
  ,ItemAsListed
  ,ai_Brand
  ,ai_ProductName
  ,ProductKeywords
  ,BrandKeywords
  ,current_fkProductId
  ,current_fkNewProductBrandId
  ,new_fkProductId
  ,new_fkNewProductBrandId
  ,matched_ProductName
  ,matched_BrandDescription
  ,kw_hits
  ,match_path
from #kw_matches
order by match_path, pkImportStagingId;
GO

-- ============================================================
-- PART 2 — UPDATE
-- Run only after confirming Part 1 results are correct.
-- ============================================================

/*
BEGIN TRANSACTION;
BEGIN TRY

update tis
set
   tis.fkProductId         = m.new_fkProductId
  ,tis.fkNewProductBrandId = m.new_fkNewProductBrandId
from TabX.ImportStaging as tis
join #kw_matches as m
   on m.pkImportStagingId = tis.pkImportStagingId
where tis.fkProductId is null;   -- guard: skip rows already assigned
                                  -- remove this line to overwrite existing assignments

select @@ROWCOUNT as rows_updated;

COMMIT TRANSACTION;
END TRY
BEGIN CATCH
   ROLLBACK TRANSACTION;
   THROW;
END CATCH;
GO

*/

drop table if exists #kw_matches;
GO
