-- repairTisFromAI_AfterDontMakeMarg.sql
-- Filtered repair: re-runs the full updateTisFromAI matching logic but restricts the
-- UPDATE to rows in TabX.ImportStaging where TabDetailDescription > 'Dont Make Marg'
-- (alphabetical comparison using the column's native CS_AS collation).
--
-- Use this script to correct product/type/container assignments for the affected
-- subset without touching earlier records.  Run normalizeImportStagingAI.sql first
-- if AI data has been refreshed since the last update pass.
--
-- All CTE logic is identical to updateTisFromAI.sql.  The only difference is the
-- additional predicate in the final WHERE clause.
--
--use TabX
--GO

BEGIN TRANSACTION;
BEGIN TRY

;with

-- ============================================================
-- Deduplicate ImportStagingAI by fkImportStagingId (FK join).
-- Drives the ProductType / ProductCategory lookups in the outer
-- UPDATE joins.
-- ============================================================
isai_dedup as (
   -- One row per ImportStaging row, using the most recent AI result
   -- (highest pkImportStagingAIId) when multiple AI rows exist for the same FK.
   -- ROW_NUMBER over max() prevents alphabetically-biased picks when AI rows disagree.
   select
      fkImportStagingId
     ,ItemAsListed
     ,ProductName
     ,ProductCategory as ProductType           -- intentionally swapped: raw ProductCategory holds TYPE data
     ,ProductType     as ProductCategory       -- intentionally swapped: raw ProductType holds CATEGORY data
     ,ContainerType
     ,IsWellKnownMixedDrink
     ,ProductKeywords
   from (
      select *,
         row_number() over (partition by fkImportStagingId order by pkImportStagingAIId desc) as ai_rn
      from TabX.ImportStagingAI
   ) as ai_ranked
   where ai_rn = 1
),

-- ============================================================
-- Normalizes AI ProductType subtypes to catalog-matchable broad
-- names (e.g. 'Bourbon' -> 'Liquor', 'India Pale Ale (IPA)' -> 'Beer').
-- The AI returns specific subtypes; Common.ProductTypes uses broad
-- category names.  Without this normalization the three-way LIKE
-- in the cpt OUTER APPLY resolves most liquor and beer items to
-- Undefined (pkProductTypeId=5), cascading to Undefined container.
-- ============================================================
isai_norm as (
   select
      d.fkImportStagingId
     ,d.ItemAsListed
     ,d.ProductName
     ,d.ContainerType
     ,d.IsWellKnownMixedDrink
     ,d.ProductKeywords
     ,d.ProductCategory
     ,coalesce(pta.NormalizedType, d.ProductType) as ProductType
   from isai_dedup as d
   outer apply (
      select NormalizedType from (values
         -- Beer subtypes -> Beer
         ('pilsner and pale lager',  'Beer'),
         ('india pale ale (ipa)',    'Beer'),
         ('specialty beer',          'Beer'),
         ('porter/stout',            'Beer'),
         ('wild/sour beer',          'Beer'),
         ('dark ale',                'Beer'),
         ('pale ale',                'Beer'),
         ('wheat beer',              'Beer'),
         -- Liquor subtypes -> Liquor
         ('blanco tequila',          'Liquor'),
         ('reposado tequila',        'Liquor'),
         ('anejo tequila',           'Liquor'),
         ('non-flavored vodka',      'Liquor'),
         ('flavored vodka',          'Liquor'),
         ('bourbon',                 'Liquor'),
         ('scotch whisky',           'Liquor'),
         ('rye',                     'Liquor'),
         ('irish whiskey',           'Liquor'),
         ('rum',                     'Liquor'),
         ('non-flavored gin',        'Liquor'),
         ('flavored gin',            'Liquor'),
         ('mezcal',                  'Liquor'),
         ('brandy',                  'Liquor'),
         ('misc whiskey',            'Liquor'),
         ('liqueurs & cordials',     'Liquor'),
         -- Wine subtypes -> Wine
         ('white wine',              'Wine'),
         ('red wine',                'Wine'),
         ('sparkling wine',          'Wine'),
         ('rose wine',               'Wine'),
         -- RTD subtypes -> RTD/Seltzer
         ('hard seltzer',            'RTD/Seltzer'),
         ('ready to drink cocktails','RTD/Seltzer'),
         -- Broad Liquor types not covered by specific subtypes
         ('tequila',                  'Liquor'),
         ('absinthe',                 'Liquor')
      ) as aliases(AIType, NormalizedType)
      where aliases.AIType = lower(trim(d.ProductType collate SQL_Latin1_General_Cp1251_CS_AS))
   ) as pta
),

-- ============================================================
-- One row per ImportStaging row (grouped by FK).
-- Used as the starting point for brand and product resolution.
-- Column swap preserved (see above).
-- ============================================================
isai_bp as (
   -- Same as isai_dedup but restricted to rows where Brand is not null,
   -- and using the most recent AI result per FK (highest pkImportStagingAIId).
   select
      fkImportStagingId
     ,Brand
     ,ProductName
     ,ProductCategory as ProductType        -- intentionally swapped
     ,ProductType     as ProductCategory    -- intentionally swapped
     ,pkImportStagingAIId
     ,ItemAsListed
     ,IsWellKnownMixedDrink
     ,ProductKeywords
   from (
      select *,
         row_number() over (partition by fkImportStagingId order by pkImportStagingAIId desc) as ai_rn
      from TabX.ImportStagingAI
      where Brand is not null
   ) as ai_ranked
   where ai_rn = 1
),

-- ============================================================
-- Branch 1: Normal products (Brand not null, not 'Mixed Drink').
-- Brand resolution priority (most to least specific):
--   cb   exact BrandDescription match
--   cbs  exact BrandDescriptionShort match
--   sinb BrandDescription contains AI brand value
--   bins AI brand value contains BrandDescription
--   cba  BrandAliases fuzzy match
-- Rows where no brand path matches are excluded; they surface as
-- NULL in the final left join and get ZZ Undefined defaults.
-- ROW_NUMBER deduplicates when sinb/bins/alias match multiple brands;
-- highest-priority path wins, ties broken by match specificity.
-- ============================================================
brand_match as (
   select
      fkImportStagingId, pkImportStagingAIId, ItemAsListed,
      ProductName, ProductKeywords, ProductType, fkRecommendedBrandId, BrandResolved
   from (
      select
         isai.fkImportStagingId
        ,isai.pkImportStagingAIId
        ,isai.ItemAsListed
        ,isai.ProductName
        ,isai.ProductKeywords
        ,isai.ProductType
        ,coalesce(
            cb.pkBrandId,
            cbs.pkBrandId,
            sinb.pkBrandId,
            bins.pkBrandId,
            cba.fkBrandId
         ) as fkRecommendedBrandId
        ,coalesce(
            cb.BrandDescription,
            cbs.BrandDescription,
            sinb.BrandDescription,
            bins.BrandDescription,
            cbba.BrandDescription
         ) as BrandResolved
        ,row_number() over (
            partition by isai.fkImportStagingId
            order by
               case
                  when cb.pkBrandId   is not null then 1
                  when cbs.pkBrandId  is not null then 2
                  when sinb.pkBrandId is not null then 3
                  when bins.pkBrandId is not null then 4
                  when cba.fkBrandId  is not null then 5
                  else 6
               end,
               coalesce(len(sinb.BrandDescription), 9999),   -- sinb: prefer shorter brand (more specific)
               coalesce(len(bins.BrandDescription), 0) desc  -- bins: prefer longer brand (more specific)
         ) as brand_rank
      from isai_bp as isai
      -- 1. exact BrandDescription
      left outer join Common.Brands as cb
         on (lower(trim(cb.BrandDescription))        = lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS))
             and cb.IsActive = 1)
      -- 2. exact BrandDescriptionShort
      left outer join Common.Brands as cbs
         on (lower(trim(cbs.BrandDescriptionShort))  = lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS))
             and cbs.IsActive = 1)
      -- 3. brand description contains AI value (sinb — substring in brand)
      left outer join Common.Brands as sinb
         on (lower(sinb.BrandDescription)            like lower('%' + trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
             and sinb.IsActive = 1)
      -- 4. AI value contains brand description (bins — brand in substring)
      left outer join Common.Brands as bins
         on (lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(bins.BrandDescription) + '%')
             and bins.IsActive = 1)
      -- 5. BrandAliases fuzzy match
      left outer join Common.BrandAliases as cba
         on (lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(cba.BrandAlias) + '%')
             and cba.IsActive = 1)
      -- resolve alias → full brand description for display
      left outer join Common.Brands as cbba
         on (cbba.pkBrandId = cba.fkBrandId and cbba.IsActive = 1)
      where lower(trim(isai.Brand)) <> 'mixed drink'
      and lower(trim(isai.ProductType)) <> 'mixed drink'   -- also exclude items the AI typed as Mixed Drink
      and not (
         cb.pkBrandId  is null
         and cbs.pkBrandId  is null
         and sinb.pkBrandId is null
         and bins.pkBrandId is null
         and cba.fkBrandId  is null
      )
   ) ranked
   where brand_rank = 1
),

-- ============================================================
-- Branch 1 continued: product matching layered on brand_match.
-- Product resolution priority (most to least specific):
--   cp    exact ProductName match on resolved brand
--   cpial exact ItemAsListed match on resolved brand
--   sinp  ProductName contains AI name — OUTER APPLY TOP 1 picks shortest (tightest) match
--   pins  AI name contains ProductName
--   cpap  ProductAliases fuzzy match
-- fkRecommendedProductId: first non-null from the chain above.
-- ============================================================
product_match as (
   select
      bm.fkImportStagingId
     ,bm.pkImportStagingAIId
     ,bm.ItemAsListed
     ,bm.ProductName
     ,bm.BrandResolved
     ,bm.fkRecommendedBrandId
     ,cbr.fkDefaultProductId
     ,coalesce(
         cp.pkProductId,
         cpial.pkProductId,
         kw_match.pkProductId,        -- keyword match (high priority)
         sinp.pkProductId,
         pins.pkProductId,
         cpap.pkProductId,
         token_match.pkProductId,
         name_only_match.pkProductId, -- exact name, any brand
         sinp_xbrand.pkProductId      -- catalog name contains AI name, any brand (catches 'Generic Gin' for AI 'Gin')
      ) as fkRecommendedProductId
     ,cphr.ProductName   as InfProdName      -- human-readable name of the resolved product
   from brand_match as bm
   -- pull resolved brand record for default product and IsNewProduct comparison
   left outer join Common.Brands   as cbr
      on (cbr.pkBrandId = bm.fkRecommendedBrandId and cbr.IsActive = 1)
   -- 1. exact ProductName (same brand)
   left outer join Common.Products as cp
      on (lower(cp.ProductName)   = lower(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)
          and bm.fkRecommendedBrandId = cp.fkBrandId and cp.IsActive = 1)
   -- 2. exact ItemAsListed (same brand)
   left outer join Common.Products as cpial
      on (lower(cpial.ProductName) = lower(bm.ItemAsListed collate SQL_Latin1_General_Cp1251_CS_AS)
          and bm.fkRecommendedBrandId = cpial.fkBrandId and cpial.IsActive = 1)
   -- 3. ProductKeywords match: any pipe-delimited keyword from ImportStagingAI appears as whole word
   --    in Common.Products.ProductName (same brand). High-priority match based on AI-identified
   --    distinguishing terms (e.g. 'Fire' for Jack Daniel's Tennessee Fire Whiskey).
   outer apply (
      select top 1 p.pkProductId
      from string_split(bm.ProductKeywords, '|') as kw
      join Common.Products as p
         on p.fkBrandId = bm.fkRecommendedBrandId
        and p.IsActive = 1
        and len(trim(kw.value)) > 2
        and ' ' + lower(p.ProductName) + ' ' like '% ' + lower(trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS)) + ' %'
      where bm.ProductKeywords is not null
      group by p.pkProductId, p.ProductName
      order by count(*) desc, len(p.ProductName) asc, p.pkProductId asc
   ) as kw_match
   -- 4. product name contains AI name — sinp (same brand); TOP 1 shortest (tightest) match eliminates fan-out
   outer apply (
      select top 1 pkProductId, ProductName
      from Common.Products
      where lower(ProductName) like lower('%' + trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
        and fkBrandId = bm.fkRecommendedBrandId
        and IsActive = 1
      order by len(ProductName) asc, pkProductId asc
   ) as sinp
   -- 5. AI name contains product name — pins (same brand); TOP 1 longest (most specific) match eliminates fan-out
   outer apply (
      select top 1 pkProductId, ProductName
      from Common.Products
      where lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(ProductName) + '%')
        and fkBrandId = bm.fkRecommendedBrandId
        and IsActive = 1
      order by len(ProductName) desc, pkProductId asc
   ) as pins
   -- 6. ProductAliases fuzzy match; TOP 1 shortest alias (most specific) eliminates fan-out when multiple aliases match
   outer apply (
      select top 1 cpap.pkProductId
      from Common.ProductAliases as cpa
      join Common.Products as cpap
         on cpap.pkProductId = cpa.fkProductId
        and cpap.fkBrandId = bm.fkRecommendedBrandId
        and cpap.IsActive = 1
      where lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(cpa.ProductAlias) + '%')
        and cpa.IsActive = 1
      order by len(cpa.ProductAlias) asc, cpa.fkProductId asc
   ) as cpap
   -- 7. Token-overlap match (same brand)
   -- Splits the catalog product name into word tokens, excludes tokens that are part of the
   -- brand description, then checks what fraction of the remaining significant tokens
   -- (length > 2) appear as whole words in the AI product name.
   -- Requires >= 45% coverage; TOP 1 ordered by coverage desc prevents fan-out.
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where p.fkBrandId = bm.fkRecommendedBrandId
        and p.IsActive = 1
        and cbr.BrandDescription is not null
        and (select count(*)
             from string_split(lower(p.ProductName), ' ') as s
             where len(s.value) > 2
               and ' ' + lower(cbr.BrandDescription) + ' ' not like '% ' + s.value + ' %'
               and ' ' + lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) + ' ' like '% ' + s.value + ' %'
            ) >= 1
        and (select count(*)
             from string_split(lower(p.ProductName), ' ') as s
             where len(s.value) > 2
               and ' ' + lower(cbr.BrandDescription) + ' ' not like '% ' + s.value + ' %'
               and ' ' + lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) + ' ' like '% ' + s.value + ' %'
            ) * 20
            >= (select count(*)
                from string_split(lower(p.ProductName), ' ') as s
                where len(s.value) > 2
                  and ' ' + lower(cbr.BrandDescription) + ' ' not like '% ' + s.value + ' %'
               ) * 9
      order by
         (select count(*)
          from string_split(lower(p.ProductName), ' ') as s
          where len(s.value) > 2
            and ' ' + lower(cbr.BrandDescription) + ' ' not like '% ' + s.value + ' %'
            and ' ' + lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) + ' ' like '% ' + s.value + ' %'
         ) desc,
         len(p.ProductName) asc,
         p.pkProductId asc
   ) as token_match
   -- 8. Name-only fallback: exact ProductName match across all brands (last resort).
   --    Generic brand (pkBrandId=2) preferred over brand-specific duplicates.
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS))
        and p.IsActive = 1
      order by case when p.fkBrandId = 2 then 0 else 1 end, p.pkProductId asc
   ) as name_only_match
   -- 9. Cross-brand sinp: catalog ProductName contains AI name as a whole word or phrase (any brand).
   --    Ordering: type-matched products first, then Generic brand, then 'Generic X' names, then shortest.
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where (   lower(p.ProductName) like lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + ' %')
             or lower(p.ProductName) like lower('% ' + trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + ' %')
             or lower(p.ProductName) like lower('% ' + trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)))
        and p.IsActive = 1
        and len(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) >= 3
      order by
         case when exists (
            select 1 from Common.ProductTypes as pt_x
            where pt_x.pkProductTypeId = p.fkProductTypeId
              and pt_x.IsActive = 1
              and trim(bm.ProductType) <> ''
              and (   lower(trim(pt_x.TypeDescription)) = lower(trim(bm.ProductType))
                   or lower(trim(pt_x.TypeDescription)) like lower('%' + trim(bm.ProductType) + '%')
                   or lower(trim(bm.ProductType))        like lower('%' + trim(pt_x.TypeDescription) + '%'))
         ) then 0 else 1 end,
         case when p.fkBrandId = 2 then 0 else 1 end,
         case when lower(p.ProductName) like 'generic %' then 0 else 1 end,
         len(p.ProductName) asc,
         p.pkProductId asc
   ) as sinp_xbrand
   -- resolve final matched product for display / alias comparison
   left outer join Common.Products as cphr
      on (cphr.pkProductId = coalesce(
            cp.pkProductId, cpial.pkProductId, kw_match.pkProductId, sinp.pkProductId,
            pins.pkProductId, cpap.pkProductId, token_match.pkProductId, name_only_match.pkProductId,
            sinp_xbrand.pkProductId,
            cbr.fkDefaultProductId)
          and cphr.IsActive = 1)
),

-- ============================================================
-- Branch 2: Well-known mixed drinks → Generic brand (pkBrandId=2).
-- IsWellKnownMixedDrink = 1 (set by AI) routes here.
-- Product search restricted to fkProductTypeId = 4 (Mixed Drink).
-- ============================================================
md_wellknown as (
   select
      isai.fkImportStagingId
     ,isai.pkImportStagingAIId
     ,isai.ItemAsListed
     ,isai.ProductName
     ,case when lower(trim(isai.Brand)) = 'mixed drink' then cast('Generic' as varchar(100)) else brand_res.BrandDesc  end as BrandResolved
     ,case when lower(trim(isai.Brand)) = 'mixed drink' then 2                               else brand_res.pkBrandId end as fkRecommendedBrandId
     ,cast(null as int)                as fkDefaultProductId
     ,coalesce(
         cp.pkProductId,
         cpial.pkProductId,
         kw_match.pkProductId,
         case when lower(trim(isai.Brand)) = 'mixed drink' then token_match.pkProductId end,
         case when lower(trim(isai.Brand)) = 'mixed drink' then sinp.pkProductId end,
         case when lower(trim(isai.Brand)) = 'mixed drink' then pins.pkProductId end,
         cpap.pkProductId
      ) as fkRecommendedProductId
     ,cphr.ProductName   as InfProdName
   from isai_bp as isai
   outer apply (
      select top 1
         coalesce(cb.pkBrandId, cbs.pkBrandId, sinb.pkBrandId, bins.pkBrandId, cba.fkBrandId)           as pkBrandId
        ,coalesce(cb.BrandDescription, cbs.BrandDescription, sinb.BrandDescription, bins.BrandDescription, cbba.BrandDescription) as BrandDesc
      from (select 1 as x) as one
      left outer join Common.Brands as cb
         on lower(trim(cb.BrandDescription))       = lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS))
        and cb.IsActive = 1
      left outer join Common.Brands as cbs
         on lower(trim(cbs.BrandDescriptionShort)) = lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS))
        and cbs.IsActive = 1
      left outer join Common.Brands as sinb
         on lower(sinb.BrandDescription)           like lower('%' + trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
        and sinb.IsActive = 1
      left outer join Common.Brands as bins
         on lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(bins.BrandDescription) + '%')
        and bins.IsActive = 1
      left outer join Common.BrandAliases as cba
         on lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(cba.BrandAlias) + '%')
        and cba.IsActive = 1
      left outer join Common.Brands as cbba
         on cbba.pkBrandId = cba.fkBrandId and cbba.IsActive = 1
      where lower(trim(isai.Brand)) <> 'mixed drink'
      order by
         case
            when cb.pkBrandId   is not null then 1
            when cbs.pkBrandId  is not null then 2
            when sinb.pkBrandId is not null then 3
            when bins.pkBrandId is not null then 4
            when cba.fkBrandId  is not null then 5
            else 6
         end,
         coalesce(len(sinb.BrandDescription), 9999),
         coalesce(len(bins.BrandDescription), 0) desc
   ) as brand_res
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)
        and p.fkProductTypeId = 4
        and p.IsActive = 1
      order by p.pkProductId asc
   ) as cp
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(isai.ItemAsListed collate SQL_Latin1_General_Cp1251_CS_AS)
        and p.fkProductTypeId = 4
        and p.IsActive = 1
      order by p.pkProductId asc
   ) as cpial
   outer apply (
      select top 1 p.pkProductId
      from string_split(isai.ProductKeywords, '|') as kw
      join Common.Products as p
         on p.fkProductTypeId = 4
        and p.IsActive = 1
        and len(trim(kw.value)) > 2
        and ' ' + lower(p.ProductName) + ' ' like '% ' + lower(trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS)) + ' %'
      where isai.ProductKeywords is not null
      group by p.pkProductId, p.ProductName
      order by count(*) desc, len(p.ProductName) asc, p.pkProductId asc
   ) as kw_match
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where p.fkProductTypeId = 4
        and p.IsActive = 1
        and lower(trim(isai.Brand)) = 'mixed drink'
        and (select count(*)
             from string_split(lower(p.ProductName), ' ') as s
             where len(s.value) > 2
               and ' generic ' not like '% ' + s.value + ' %'
               and ' ' + lower(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) + ' ' like '% ' + s.value + ' %'
            ) >= 1
        and (select count(*)
             from string_split(lower(p.ProductName), ' ') as s
             where len(s.value) > 2
               and ' generic ' not like '% ' + s.value + ' %'
               and ' ' + lower(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) + ' ' like '% ' + s.value + ' %'
            ) * 20
            >= (select count(*)
                from string_split(lower(p.ProductName), ' ') as s
                where len(s.value) > 2
                  and ' generic ' not like '% ' + s.value + ' %'
               ) * 9
      order by
         (select count(*)
          from string_split(lower(p.ProductName), ' ') as s
          where len(s.value) > 2
            and ' generic ' not like '% ' + s.value + ' %'
            and ' ' + lower(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) + ' ' like '% ' + s.value + ' %'
         ) desc,
         len(p.ProductName) asc,
         p.pkProductId asc
   ) as token_match
   outer apply (
      select top 1 pkProductId, ProductName
      from Common.Products
      where lower(ProductName) like lower('%' + trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
        and fkProductTypeId = 4
        and IsActive = 1
      order by len(ProductName) asc, pkProductId asc
   ) as sinp
   outer apply (
      select top 1 pkProductId, ProductName
      from Common.Products
      where lower(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(ProductName) + '%')
        and fkProductTypeId = 4
        and IsActive = 1
      order by len(ProductName) desc, pkProductId asc
   ) as pins
   outer apply (
      select top 1 cpap.pkProductId
      from Common.ProductAliases as cpa
      join Common.Products as cpap
         on cpap.pkProductId = cpa.fkProductId
        and cpap.fkProductTypeId = 4
        and cpap.IsActive = 1
      where lower(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(cpa.ProductAlias) + '%')
        and cpa.IsActive = 1
      order by len(cpa.ProductAlias) asc, cpa.fkProductId asc
   ) as cpap
   left outer join Common.Products as cphr
      on (cphr.pkProductId = coalesce(
            cp.pkProductId, cpial.pkProductId, kw_match.pkProductId,
            case when lower(trim(isai.Brand)) = 'mixed drink' then token_match.pkProductId end,
            case when lower(trim(isai.Brand)) = 'mixed drink' then sinp.pkProductId end,
            case when lower(trim(isai.Brand)) = 'mixed drink' then pins.pkProductId end,
            cpap.pkProductId)
          and cphr.IsActive = 1)
   where (lower(trim(isai.Brand)) = 'mixed drink' or lower(trim(isai.ProductType)) = 'mixed drink')
   and isai.IsWellKnownMixedDrink = 1

   union all

   -- Null-brand items tagged as well-known (IsWellKnownMixedDrink=1) typed as Mixed Drink.
   -- isai_bp excludes null-brand rows, so this path catches them via isai_norm.
   -- Treated identically to generic 'Mixed Drink' brand: brand resolves to pkBrandId=2.
   select
      isai_d.fkImportStagingId
     ,cast(null as int)               as pkImportStagingAIId
     ,isai_d.ItemAsListed
     ,isai_d.ProductName
     ,cast('Generic' as varchar(100)) as BrandResolved
     ,cast(2 as int)                  as fkRecommendedBrandId
     ,cast(null as int)               as fkDefaultProductId
     ,coalesce(
         cp_d.pkProductId,
         cpial_d.pkProductId,
         kw_d.pkProductId,
         sinp_d.pkProductId,
         pins_d.pkProductId,
         cpap_d.pkProductId
      ) as fkRecommendedProductId
     ,cphr_d.ProductName              as InfProdName
   from isai_norm as isai_d
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)
        and p.fkProductTypeId = 4
        and p.IsActive = 1
      order by p.pkProductId asc
   ) as cp_d
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(isai_d.ItemAsListed collate SQL_Latin1_General_Cp1251_CS_AS)
        and p.fkProductTypeId = 4
        and p.IsActive = 1
      order by p.pkProductId asc
   ) as cpial_d
   outer apply (
      select top 1 p.pkProductId
      from string_split(isai_d.ProductKeywords, '|') as kw
      join Common.Products as p
         on p.fkProductTypeId = 4
        and p.IsActive = 1
        and len(trim(kw.value)) > 2
        and ' ' + lower(p.ProductName) + ' ' like '% ' + lower(trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS)) + ' %'
      where isai_d.ProductKeywords is not null
      group by p.pkProductId, p.ProductName
      order by count(*) desc, len(p.ProductName) asc, p.pkProductId asc
   ) as kw_d
   outer apply (
      select top 1 pkProductId, ProductName
      from Common.Products
      where lower(ProductName) like lower('%' + trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
        and fkProductTypeId = 4
        and IsActive = 1
      order by len(ProductName) asc, pkProductId asc
   ) as sinp_d
   outer apply (
      select top 1 pkProductId, ProductName
      from Common.Products
      where lower(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(ProductName) + '%')
        and fkProductTypeId = 4
        and IsActive = 1
      order by len(ProductName) desc, pkProductId asc
   ) as pins_d
   outer apply (
      select top 1 cpap.pkProductId
      from Common.ProductAliases as cpa
      join Common.Products as cpap
         on cpap.pkProductId = cpa.fkProductId
        and cpap.fkProductTypeId = 4
        and cpap.IsActive = 1
      where lower(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(cpa.ProductAlias) + '%')
        and cpa.IsActive = 1
      order by len(cpa.ProductAlias) asc, cpa.fkProductId asc
   ) as cpap_d
   left outer join Common.Products as cphr_d
      on (cphr_d.pkProductId = coalesce(cp_d.pkProductId, cpial_d.pkProductId, kw_d.pkProductId,
            sinp_d.pkProductId, pins_d.pkProductId, cpap_d.pkProductId)
          and cphr_d.IsActive = 1)
   where lower(trim(isai_d.ProductType)) = 'mixed drink'
     and isai_d.IsWellKnownMixedDrink = 1
     and not exists (select 1 from isai_bp as bp where bp.fkImportStagingId = isai_d.fkImportStagingId)
),

-- ============================================================
-- Branch 3: Unknown / proprietary mixed drinks → location name as brand.
-- IsWellKnownMixedDrink = 0 (or NULL for backward compat) routes here.
-- ============================================================
md_unknown as (
   select
      isai.fkImportStagingId
     ,isai.pkImportStagingAIId
     ,isai.ItemAsListed
     ,isai.ProductName
     ,cast(null as varchar(100))   as BrandResolved
     ,cast(null as int)            as fkRecommendedBrandId
     ,cast(null as int)            as fkDefaultProductId
     ,exact_match.pkProductId      as fkRecommendedProductId
     ,exact_match.ProductName      as InfProdName
   from isai_bp as isai
   outer apply (
      select top 1 p.pkProductId, p.ProductName
      from Common.Products as p
      where p.fkProductTypeId = 4
        and p.IsActive = 1
        and (   lower(p.ProductName) = lower(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)
             or lower(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(p.ProductName) + '%'))
      order by
         case when lower(p.ProductName) = lower(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) then 0 else 1 end,
         len(p.ProductName) desc,   -- longest catalog name wins among substring matches
         p.pkProductId asc
   ) as exact_match
   where (lower(trim(isai.Brand)) = 'mixed drink' or lower(trim(isai.ProductType)) = 'mixed drink')
   and coalesce(isai.IsWellKnownMixedDrink, 0) = 0

   union all

   -- Null-brand items typed as Mixed Drink: isai_bp excludes rows where Brand is null,
   -- so these are not caught by the branch above.
   select
      isai_d.fkImportStagingId
     ,cast(null as int)            as pkImportStagingAIId
     ,isai_d.ItemAsListed
     ,isai_d.ProductName
     ,cast(null as varchar(100))   as BrandResolved
     ,cast(null as int)            as fkRecommendedBrandId
     ,cast(null as int)            as fkDefaultProductId
     ,exact_match_d.pkProductId    as fkRecommendedProductId
     ,exact_match_d.ProductName    as InfProdName
   from isai_norm as isai_d
   outer apply (
      select top 1 p.pkProductId, p.ProductName
      from Common.Products as p
      where p.fkProductTypeId = 4
        and p.IsActive = 1
        and (   lower(p.ProductName) = lower(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)
             or lower(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(p.ProductName) + '%'))
      order by
         case when lower(p.ProductName) = lower(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) then 0 else 1 end,
         len(p.ProductName) desc,
         p.pkProductId asc
   ) as exact_match_d
   where lower(trim(isai_d.ProductType)) = 'mixed drink'
     and coalesce(isai_d.IsWellKnownMixedDrink, 0) = 0
     and not exists (select 1 from isai_bp as bp where bp.fkImportStagingId = isai_d.fkImportStagingId)
),

-- ============================================================
-- Branch 4: No-brand fallback — items where the AI returned null
-- or an unrecognized brand, and no mixed drink routing applied.
-- ============================================================
no_brand_match as (
   select
      isai_d.fkImportStagingId
     ,isai_d_bp.pkImportStagingAIId
     ,isai_d.ItemAsListed
     ,isai_d.ProductName
     ,cast(null as varchar(100))  as BrandResolved
     ,cast(null as int)           as fkRecommendedBrandId
     ,cast(null as int)           as fkDefaultProductId
     ,coalesce(cp.pkProductId, cpial.pkProductId, kw_nb.pkProductId, sinp_nb.pkProductId) as fkRecommendedProductId
     ,cphr.ProductName            as InfProdName
   from isai_norm as isai_d
   left outer join isai_bp as isai_d_bp
      on isai_d_bp.fkImportStagingId = isai_d.fkImportStagingId
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS))
        and p.IsActive = 1
      order by case when p.fkBrandId = 2 then 0 else 1 end, p.pkProductId asc
   ) as cp
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(trim(isai_d.ItemAsListed collate SQL_Latin1_General_Cp1251_CS_AS))
        and p.IsActive = 1
      order by case when p.fkBrandId = 2 then 0 else 1 end, p.pkProductId asc
   ) as cpial
   outer apply (
      select top 1 p.pkProductId
      from string_split(isai_d.ProductKeywords, '|') as kw
      join Common.Products as p
         on p.IsActive = 1
        and len(trim(kw.value)) > 2
        and ' ' + lower(p.ProductName) + ' ' like '% ' + lower(trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS)) + ' %'
      where isai_d.ProductKeywords is not null
      group by p.pkProductId, p.ProductName
      order by count(*) desc, len(p.ProductName) asc, p.pkProductId asc
   ) as kw_nb
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where (   lower(p.ProductName) like lower(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + ' %')
             or lower(p.ProductName) like lower('% ' + trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + ' %')
             or lower(p.ProductName) like lower('% ' + trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)))
        and p.IsActive = 1
        and len(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) >= 3
      order by
         case when exists (
            select 1 from Common.ProductTypes as pt_nb
            where pt_nb.pkProductTypeId = p.fkProductTypeId
              and pt_nb.IsActive = 1
              and trim(isai_d.ProductType) <> ''
              and (   lower(trim(pt_nb.TypeDescription)) = lower(trim(isai_d.ProductType))
                   or lower(trim(pt_nb.TypeDescription)) like lower('%' + trim(isai_d.ProductType) + '%')
                   or lower(trim(isai_d.ProductType))    like lower('%' + trim(pt_nb.TypeDescription) + '%'))
         ) then 0 else 1 end,
         case when p.fkBrandId = 2 then 0 else 1 end,
         case when lower(p.ProductName) like 'generic %' then 0 else 1 end,
         len(p.ProductName) asc,
         p.pkProductId asc
   ) as sinp_nb
   left outer join Common.Products as cphr
      on cphr.pkProductId = coalesce(cp.pkProductId, cpial.pkProductId, kw_nb.pkProductId, sinp_nb.pkProductId)
     and cphr.IsActive = 1
   where not exists (select 1 from brand_match  as bm where bm.fkImportStagingId = isai_d.fkImportStagingId)
   and   not exists (select 1 from md_wellknown as mw where mw.fkImportStagingId = isai_d.fkImportStagingId)
   and   not exists (select 1 from md_unknown   as mu where mu.fkImportStagingId = isai_d.fkImportStagingId)
   and   lower(trim(isai_d.ProductType)) <> 'mixed drink'
),

-- ============================================================
-- Union all four branches.
-- ============================================================
all_matches as (
   select
      fkImportStagingId, pkImportStagingAIId, ItemAsListed, ProductName, BrandResolved,
      fkRecommendedBrandId, fkDefaultProductId, fkRecommendedProductId,
      InfProdName
   from product_match

   union all

   select
      fkImportStagingId, pkImportStagingAIId, ItemAsListed, ProductName, BrandResolved,
      fkRecommendedBrandId, fkDefaultProductId, fkRecommendedProductId,
      InfProdName
   from md_wellknown

   union all

   select
      fkImportStagingId, pkImportStagingAIId, ItemAsListed, ProductName, BrandResolved,
      fkRecommendedBrandId, fkDefaultProductId, fkRecommendedProductId,
      InfProdName
   from md_unknown

   union all

   select
      fkImportStagingId, pkImportStagingAIId, ItemAsListed, ProductName, BrandResolved,
      fkRecommendedBrandId, fkDefaultProductId, fkRecommendedProductId,
      InfProdName
   from no_brand_match
)

-- ============================================================
-- Main UPDATE — filtered to TabDetailDescription > 'Dont Make Marg'
-- ============================================================
update tis
set

   fkProductId =
   case
      when cpt.pkProductTypeId = 6  then 12241
      when cpt.pkProductTypeId = 5  then 1
      when cpt.pkProductTypeId = 7  then 1
      when cpt.pkProductTypeId = 11 then 1
      when cpt.pkProductTypeId = 4
        or lower(trim(isai_d.ProductType)) = 'mixed drink'
         then coalesce(ss.fkRecommendedProductId, 12257)
      when ss.fkRecommendedProductId is not null then ss.fkRecommendedProductId
      when ss.fkRecommendedBrandId  is null then 1
      else cbr.fkDefaultProductId
   end

  ,fkContainerId =
   case
      when cpt.pkProductTypeId = 1  then
         case
            when lower(isai_d.ContainerType) = 'bottle'
              or lower(tis.TabDetailDescription) like '%bottle%'
              or ' ' + lower(tis.TabDetailDescription) + ' ' like '% bt %'
              or ' ' + lower(tis.TabDetailDescription) + ' ' like '% btl %' then 44  -- bottle
            when lower(isai_d.ContainerType) = 'can'
              or lower(tis.TabDetailDescription) like '%can%'                then 27  -- can
            else 5                                                                    -- default: 16oz draft
         end
      when cpt.pkProductTypeId = 2  then
         case
            when lower(isai_d.ContainerType) like '%double%'
              or lower(tis.TabDetailDescription) like '%dbl%'
              or lower(tis.TabDetailDescription) like '%double%' then 30  -- double shot
            else 26                                                        -- default: 1 shot
         end
      when cpt.pkProductTypeId = 3  then
         case
            when lower(isai_d.ContainerType) = 'bottle'
              or lower(tis.TabDetailDescription) like '%bottle%'
              or ' ' + lower(tis.TabDetailDescription) + ' ' like '% bt %'
              or ' ' + lower(tis.TabDetailDescription) + ' ' like '% btl %' then 44  -- bottle
            else 33                                                                    -- default: 5oz wine glass
         end
      when cpt.pkProductTypeId = 4  then 35  -- default: 1 drink
      when cpt.pkProductTypeId = 5  then 29
      when cpt.pkProductTypeId = 6  then 32
      when cpt.pkProductTypeId = 7  then 29
      when cpt.pkProductTypeId = 8  then 40
      when cpt.pkProductTypeId = 9  then 35
      when cpt.pkProductTypeId = 10 then 35
      when cpt.pkProductTypeId = 11 then 32
      when cpt.pkProductTypeId = 12 then 14
      when cpt.pkProductTypeId = 13 then 28
      when cpt.pkProductTypeId = 14 then 32
      else 29
   end

  ,NewProductName =
   case
      when cpt.pkProductTypeId = 6  or lower(trim(isai_d.ProductType)) in ('food','foods','food item','food & beverage','food and beverage')  then 'Generic Food'
      when cpt.pkProductTypeId = 11 or lower(trim(isai_d.ProductType)) in ('merch','merchandise','merchandising')                              then 'Generic Merch'
      when cpt.pkProductTypeId = 7  or lower(trim(isai_d.ProductType)) in ('misc','miscellaneous','other misc')                                then 'Miscellaneous'
      when cpt.pkProductTypeId = 5  or lower(trim(isai_d.ProductType)) in ('undefined','unknown','other','n/a','na','none')                    then 'Undefined'
      else isai_d.ProductName
   end

  ,IsNewProduct =
   case
      when cpt.pkProductTypeId in (5, 6, 7, 11)  then 0
      when (cpt.pkProductTypeId = 4 or lower(trim(isai_d.ProductType)) = 'mixed drink')
           and lower(trim(ibp.Brand)) = 'mixed drink'  then 0
      when ss.fkRecommendedProductId is null
           and isai_d.ProductKeywords is not null  then 1
      else 0
   end

  ,IsNewProductAlias =
   case
      when cpt.pkProductTypeId in (5, 6, 7, 11)   then 0
      when ss.fkRecommendedProductId is null       then 0
      when lower(trim(ss.ProductName)) = lower(trim(ss.InfProdName)) then 0
      else 1
   end

  ,fkProductTypeId    = coalesce(cpt.pkProductTypeId, 5)
  ,fkProductCategoryId = cpc.pkProductCategoryId
  ,fkNewProductBrandId = ss.fkRecommendedBrandId

  ,NewProductBrand =
   case
      when cpt.pkProductTypeId in (5, 6, 7, 11) then null
      when (cpt.pkProductTypeId = 4 or lower(trim(isai_d.ProductType)) = 'mixed drink')
           and isai_d.IsWellKnownMixedDrink = 1 then null
      when (cpt.pkProductTypeId = 4 or lower(trim(isai_d.ProductType)) = 'mixed drink')
           and coalesce(isai_d.IsWellKnownMixedDrink, 0) = 0 then loc.Name
      when ss.fkRecommendedProductId is null and ss.fkRecommendedBrandId is null
         then ibp.Brand collate SQL_Latin1_General_Cp1251_CS_AS
      else null
   end

from TabX.ImportStaging as tis

left outer join isai_norm as isai_d
   on isai_d.fkImportStagingId = tis.pkImportStagingId

left outer join isai_bp as ibp
   on ibp.fkImportStagingId = tis.pkImportStagingId

left outer join all_matches as ss
   on ss.fkImportStagingId = tis.pkImportStagingId

outer apply (
   select top 1 pkProductTypeId, TypeDescription
   from Common.ProductTypes
   where IsActive = 1
     and trim(isai_d.ProductType) <> ''
     and lower(trim(TypeDescription)) = lower(trim(isai_d.ProductType))
   order by pkProductTypeId asc
) as cpt

outer apply (
   select top 1 pc.pkProductCategoryId, pc.CategoryName
   from Common.ProductCategories as pc
   where pc.IsActive = 1
     and trim(isai_d.ProductCategory) <> ''
     and (   lower(trim(pc.CategoryName)) = lower(trim(isai_d.ProductCategory))
          or lower(trim(pc.CategoryName)) like lower('%' + trim(isai_d.ProductCategory) + '%')
          or lower(trim(isai_d.ProductCategory)) like lower('%' + trim(pc.CategoryName) + '%'))
   order by
      case when cpt.pkProductTypeId is not null
            and exists (select 1 from Common.Products as p
                        where p.fkProductCategoryId = pc.pkProductCategoryId
                          and p.fkProductTypeId = cpt.pkProductTypeId
                          and p.IsActive = 1)
           then 0 else 1 end,
      case
         when lower(trim(pc.CategoryName)) = lower(trim(isai_d.ProductCategory))                then 0
         when lower(trim(pc.CategoryName)) like lower('%' + trim(isai_d.ProductCategory) + '%') then 1
         else 2
      end,
      case
         when lower(trim(pc.CategoryName)) like lower('%' + trim(isai_d.ProductCategory) + '%')
            then len(pc.CategoryName)
         else 9999 - len(pc.CategoryName)
      end,
      pc.pkProductCategoryId asc
) as cpc

left outer join Common.Brands as cbr
   on (cbr.pkBrandId = ss.fkRecommendedBrandId and cbr.IsActive = 1)

left outer join TabX.Locations as loc
   on loc.pkLocationId = tis.fkLocationId

where isai_d.fkImportStagingId is not null
  and tis.fkProductId <> 16676                      -- skip RR Research Market Rep rows
  and tis.TabDetailDescription > 'Dont Make Marg'   -- only repair records alphabetically after this sentinel

COMMIT TRANSACTION;
END TRY
BEGIN CATCH
   ROLLBACK TRANSACTION;
   THROW;
END CATCH
GO
