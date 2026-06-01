-- kwMatchProducts.sql
-- Joins ImportStaging + ImportStagingAI and uses pipe-delimited BrandKeywords
-- and ProductKeywords to find the best matching product in Common.Products.
--
-- Two-pass match strategy:
--
--   PRIMARY (brand-scoped)
--     ProductKeywords tokens matched as substrings in Products.ProductName,
--     restricted to the brand resolved from BrandKeywords.
--     Fast and precise when the product is correctly linked to its brand via fkBrandId.
--
--   FALLBACK (cross-brand, fires only when primary finds nothing)
--     BrandKeywords + ProductKeywords tokens are pooled and all matched as
--     substrings in Products.ProductName across all active products.
--     Catches products whose fkBrandId is NULL or whose brand name appears
--     inside the product name (e.g. BrandKeywords='Chartreuse',
--     ProductKeywords='Green' -> 'Chartreuse Green').
--
-- match_path column shows which path fired per row.
-- Tokens <= 2 chars are skipped (noise guard, consistent with updateTisFromAI).
--
-- use TabX
-- GO

;with

-- One row per ImportStaging: take the most recent ISAI row if there are duplicates
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

-- Count how many BrandKeywords tokens appear as substrings in Brands.BrandDescription
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

-- Best brand per row: most hits wins; ties broken by shorter name, then lower PK
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

-- PRIMARY: ProductKeywords tokens in ProductName, scoped to the resolved brand
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

-- FALLBACK: fires only when primary found nothing.
-- Pools BrandKeywords + ProductKeywords and matches all tokens against
-- ProductName cross-brand. Each token hit adds 1 to the score, so products
-- containing more of the keywords rank higher.
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
   where bpr.fkImportStagingId is null   -- anti-join: only when primary found nothing
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
  ,coalesce(bpr.ProductName,    bfb.ProductName)           as matched_ProductName
  ,b.BrandDescription                                      as matched_BrandDescription
  ,coalesce(bpr.kw_hits,        bfb.kw_hits)               as kw_hits
  ,case
      when bpr.pkProductId is not null then 'brand-scoped'
      when bfb.pkProductId is not null then 'fallback'
      else 'no match'
   end                                                     as match_path

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

order by tis.pkImportStagingId
GO
