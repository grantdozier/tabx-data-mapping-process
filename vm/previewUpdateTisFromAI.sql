-- previewUpdateTisFromAI.sql
-- SELECT-only preview of updateTisFromAI.sql.
-- Shows the values the update WOULD write without modifying the database.
-- Only output columns (new_*) are shown; current values and diagnostics are omitted.
--
-- Rows where no AI data exists for the item are excluded
-- (WHERE isai_d.fkImportStagingId is not null).
-- Results ordered by TabDetailDescription for easy review.
--
--use TabX
--GO

;with

isai_dedup as (
   select
      fkImportStagingId
     ,max(ItemAsListed)    as ItemAsListed          -- aggregated reference
     ,max(ProductName)     as ProductName           -- used directly as NewProductName
     ,max(ProductCategory) as ProductType           -- intentionally swapped: raw ProductCategory holds TYPE data — matched to ProductTypes below
     ,max(ProductType)     as ProductCategory       -- intentionally swapped: raw ProductType holds CATEGORY data — matched to ProductCategories below
     ,max(ContainerType)       as ContainerType         -- reserved for future Common.Containers lookup
     ,max(IsWellKnownMixedDrink) as IsWellKnownMixedDrink  -- 1=well-known cocktail, 0=proprietary, NULL=not a mixed drink
     ,max(ProductKeywords)       as ProductKeywords          -- pipe-delimited distinguishing keywords (diagnostic)
   from TabX.ImportStagingAI
   group by fkImportStagingId
),

isai_bp as (
   select
      fkImportStagingId
     ,max(Brand)               as Brand
     ,max(ProductName)         as ProductName
     ,max(ProductCategory)     as ProductType        -- intentionally swapped
     ,max(ProductType)         as ProductCategory    -- intentionally swapped
     ,max(pkImportStagingAIId) as pkImportStagingAIId
     ,max(ItemAsListed)        as ItemAsListed
     ,max(IsWellKnownMixedDrink) as IsWellKnownMixedDrink  -- 1=well-known cocktail, 0=proprietary, NULL=not a mixed drink
     ,max(ProductKeywords)       as ProductKeywords          -- pipe-delimited distinguishing keywords for product matching
   from TabX.ImportStagingAI
   where Brand is not null
   group by fkImportStagingId
),

brand_match as (
   select
      fkImportStagingId, pkImportStagingAIId, ItemAsListed,
      ProductName, ProductKeywords, fkRecommendedBrandId, BrandResolved
   from (
      select
         isai.fkImportStagingId
        ,isai.pkImportStagingAIId
        ,isai.ItemAsListed
        ,isai.ProductName
        ,isai.ProductKeywords
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
      left outer join Common.Brands as cb
         on (lower(trim(cb.BrandDescription))        = lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS))
             and cb.IsActive = 1)
      left outer join Common.Brands as cbs
         on (lower(trim(cbs.BrandDescriptionShort))  = lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS))
             and cbs.IsActive = 1)
      left outer join Common.Brands as sinb
         on (lower(sinb.BrandDescription)            like lower('%' + trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
             and sinb.IsActive = 1
             and len(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS)) >= 5)
      left outer join Common.Brands as bins
         on (lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS)) like lower(trim(bins.BrandDescription) + ' %')
             and bins.IsActive = 1)
      left outer join Common.BrandAliases as cba
         on (lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(cba.BrandAlias) + '%')
             and cba.IsActive = 1)
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
     ,cphr.ProductName   as InfProdName
   from brand_match as bm
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
   -- 3. ProductKeywords match: any pipe-delimited keyword from ImportStagingAI appears as substring
   --    in Common.Products.ProductName (same brand). High-priority match based on AI-identified
   --    distinguishing terms (e.g. 'Fire' for Jack Daniel's Tennessee Fire Whiskey).
   --    string_split is placed directly in the OUTER APPLY FROM clause so that the lateral
   --    reference to bm.ProductKeywords is valid (SQL Server does not allow TVF lateral refs
   --    inside nested EXISTS subqueries).
   --    Also usable against Common.ProductKeywords if that table is created.
   outer apply (
      select top 1 p.pkProductId
      from string_split(bm.ProductKeywords, '|') as kw
      join Common.Products as p
         on p.fkBrandId = bm.fkRecommendedBrandId
        and p.IsActive = 1
        and len(trim(kw.value)) >= 2
        and lower(p.ProductName) like lower('%' + trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
      where bm.ProductKeywords is not null
      group by p.pkProductId, p.ProductName
      order by count(*) desc, len(p.ProductName) asc, p.pkProductId asc  -- most keyword hits wins; length breaks ties; pkProductId breaks remaining ties deterministically
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
      where lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + ProductName + '%')
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
   -- Handles cases where catalog and AI use different verbosity or brand representations
   -- (e.g. catalog "JD Single Barrel Select" vs AI "Jack Daniel's Single Barrel Select Tennessee Whiskey").
   -- Uses COUNT(*) with correlated WHERE subqueries to avoid the SQL Server restriction
   -- "outer reference in aggregated expression".
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where p.fkBrandId = bm.fkRecommendedBrandId
        and p.IsActive = 1
        and cbr.BrandDescription is not null
        -- at least 1 significant non-brand token from catalog name appears as whole word in AI name
        and (select count(*)
             from string_split(lower(p.ProductName), ' ') as s
             where len(s.value) > 2
               and ' ' + lower(cbr.BrandDescription) + ' ' not like '% ' + s.value + ' %'
               and ' ' + lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) + ' ' like '% ' + s.value + ' %'
               and lower(s.value) not in (
                   'single','malt','scotch','whisky','whiskey','bourbon','rye',
                   'rum','gin','vodka','tequila','mezcal','liqueur',
                   'beer','ale','lager','stout','porter','seltzer',
                   'aged','blended','distilled','craft','barrel')
            ) >= 1
        -- matched * 20 >= total * 9  (i.e. matched / total >= 45%, using integer math to avoid divide-by-zero)
        and (select count(*)
             from string_split(lower(p.ProductName), ' ') as s
             where len(s.value) > 2
               and ' ' + lower(cbr.BrandDescription) + ' ' not like '% ' + s.value + ' %'
               and ' ' + lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) + ' ' like '% ' + s.value + ' %'
               and lower(s.value) not in (
                   'single','malt','scotch','whisky','whiskey','bourbon','rye',
                   'rum','gin','vodka','tequila','mezcal','liqueur',
                   'beer','ale','lager','stout','porter','seltzer',
                   'aged','blended','distilled','craft','barrel')
            ) * 20
            >= (select count(*)
                from string_split(lower(p.ProductName), ' ') as s
                where len(s.value) > 2
                  and ' ' + lower(cbr.BrandDescription) + ' ' not like '% ' + s.value + ' %'
                  and lower(s.value) not in (
                      'single','malt','scotch','whisky','whiskey','bourbon','rye',
                      'rum','gin','vodka','tequila','mezcal','liqueur',
                      'beer','ale','lager','stout','porter','seltzer',
                      'aged','blended','distilled','craft','barrel')
               ) * 9
      order by
         (select count(*)
          from string_split(lower(p.ProductName), ' ') as s
          where len(s.value) > 2
            and ' ' + lower(cbr.BrandDescription) + ' ' not like '% ' + s.value + ' %'
            and ' ' + lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) + ' ' like '% ' + s.value + ' %'
            and lower(s.value) not in (
                'single','malt','scotch','whisky','whiskey','bourbon','rye',
                'rum','gin','vodka','tequila','mezcal','liqueur',
                'beer','ale','lager','stout','porter','seltzer',
                'aged','blended','distilled','craft','barrel')
         ) desc,
         len(p.ProductName) asc,
         p.pkProductId asc   -- deterministic tiebreaker
   ) as token_match
   -- 8. Name-only fallback: exact ProductName match across all brands (last resort).
   --    Handles items where the brand resolved correctly but the product is cataloged
   --    under a different brand (e.g. AI says Brand='Canada Dry', product is under 'Generic').
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS))
        and p.IsActive = 1
      order by p.pkProductId asc
   ) as name_only_match
   -- 9. Cross-brand sinp: catalog ProductName contains AI name as a whole word or phrase
   --    (any brand). Catches generic items where the AI writes only the varietal or base
   --    name ('Gin', 'Hard Seltzer', 'Sauvignon Blanc') but the catalog stores it with a
   --    prefix or suffix ('Generic Gin', 'Generic Hard Seltzer', 'Sauvignon Blanc Wine').
   --    Word-boundary conditions prevent mid-word false positives (e.g. 'gin' in 'origin').
   --    Ordering prefers Generic brand (pkBrandId=2) then 'Generic X' named products then
   --    shortest catalog name, so 'Generic Gin' beats 'Gimlet Gin' for AI name 'Gin'.
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where (   lower(p.ProductName) like lower(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + ' %')
             or lower(p.ProductName) like lower('% ' + trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + ' %')
             or lower(p.ProductName) like lower('% ' + trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)))
        and p.IsActive = 1
        and len(trim(bm.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) >= 3
      order by
         case when p.fkBrandId = 2 then 0 else 1 end,                       -- Generic brand first
         case when lower(p.ProductName) like 'generic %' then 0 else 1 end, -- 'Generic X' names first
         len(p.ProductName) asc,                                             -- shortest (most specific) next
         p.pkProductId asc
   ) as sinp_xbrand
   left outer join Common.Products as cphr
      on (cphr.pkProductId = coalesce(
            cp.pkProductId, cpial.pkProductId, kw_match.pkProductId, sinp.pkProductId,
            pins.pkProductId, cpap.pkProductId, token_match.pkProductId, name_only_match.pkProductId,
            sinp_xbrand.pkProductId,
            cbr.fkDefaultProductId)
          and cphr.IsActive = 1)
),

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
         kw_match.pkProductId,        -- keyword match (high priority)
         -- sinp/pins are substring matches — only use for truly generic 'Mixed Drink' brand items.
         -- Brand-specific cocktails (routed here via ProductType) require exact/keyword/alias only
         -- to avoid false positives like 'Gin & Tonic' matching 'Gray Whale Gin & Tonic'.
         case when lower(trim(isai.Brand)) = 'mixed drink' then sinp.pkProductId end,
         case when lower(trim(isai.Brand)) = 'mixed drink' then pins.pkProductId end,
         cpap.pkProductId
      ) as fkRecommendedProductId
     ,cphr.ProductName   as InfProdName
   from isai_bp as isai
   -- Resolve brand for brand-specific cocktails routed here via ProductType = 'Mixed Drink'.
   -- Uses the same priority chain as brand_match; result is NULL when Brand = 'Mixed Drink'
   -- (filtered by the WHERE) or when no catalog brand matches.
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
        and len(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS)) >= 5
      left outer join Common.Brands as bins
         on lower(trim(isai.Brand collate SQL_Latin1_General_Cp1251_CS_AS)) like lower(trim(bins.BrandDescription) + ' %')
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
   -- ProductKeywords match: any pipe-delimited keyword appears as substring in ProductName
   -- (see product_match comment for why string_split must be in the APPLY FROM clause)
   outer apply (
      select top 1 p.pkProductId
      from string_split(isai.ProductKeywords, '|') as kw
      join Common.Products as p
         on p.fkProductTypeId = 4
        and p.IsActive = 1
        and len(trim(kw.value)) >= 2
        and lower(p.ProductName) like lower('%' + trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
      where isai.ProductKeywords is not null
      group by p.pkProductId, p.ProductName
      order by count(*) desc, len(p.ProductName) asc, p.pkProductId asc  -- most keyword hits wins; length breaks ties; pkProductId breaks remaining ties deterministically
   ) as kw_match
   -- sinp: product name contains AI name; TOP 1 shortest (tightest) match eliminates fan-out
   outer apply (
      select top 1 pkProductId, ProductName
      from Common.Products
      where lower(ProductName) like lower('%' + trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
        and fkProductTypeId = 4
        and IsActive = 1
      order by len(ProductName) asc, pkProductId asc
   ) as sinp
   -- pins: AI name contains product name; TOP 1 longest (most specific) match eliminates fan-out
   outer apply (
      select top 1 pkProductId, ProductName
      from Common.Products
      where lower(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + ProductName + '%')
        and fkProductTypeId = 4
        and IsActive = 1
      order by len(ProductName) desc, pkProductId asc
   ) as pins
   -- cpap: ProductAliases fuzzy match; TOP 1 shortest alias (most specific) eliminates fan-out
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
            case when lower(trim(isai.Brand)) = 'mixed drink' then sinp.pkProductId end,
            case when lower(trim(isai.Brand)) = 'mixed drink' then pins.pkProductId end,
            cpap.pkProductId)
          and cphr.IsActive = 1)
   where (lower(trim(isai.Brand)) = 'mixed drink' or lower(trim(isai.ProductType)) = 'mixed drink')
   and isai.IsWellKnownMixedDrink = 1

   union all

   -- Null-brand well-known cocktails: Brand=NULL items are excluded from isai_bp and
   -- cannot enter the branch above. Route here; assign Generic brand (2) and search
   -- fkProductTypeId=4 products directly from isai_dedup.
   -- This handles items like Generic Old Fashioned, Generic Martini, etc. where the
   -- AI correctly identifies the cocktail but leaves Brand NULL.
   select
      isai_d.fkImportStagingId
     ,cast(null as int)               as pkImportStagingAIId
     ,isai_d.ItemAsListed
     ,isai_d.ProductName
     ,cast('Generic' as varchar(100)) as BrandResolved
     ,2                               as fkRecommendedBrandId
     ,cast(null as int)               as fkDefaultProductId
     ,coalesce(
         cp_nb.pkProductId,
         cpial_nb.pkProductId,
         kw_match_nb.pkProductId,
         sinp_nb.pkProductId,
         pins_nb.pkProductId,
         cpap_nb.pkProductId
      )                               as fkRecommendedProductId
     ,cphr_nb.ProductName             as InfProdName
   from isai_dedup as isai_d
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)
        and p.fkProductTypeId = 4
        and p.IsActive = 1
      order by p.pkProductId asc
   ) as cp_nb
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(isai_d.ItemAsListed collate SQL_Latin1_General_Cp1251_CS_AS)
        and p.fkProductTypeId = 4
        and p.IsActive = 1
      order by p.pkProductId asc
   ) as cpial_nb
   outer apply (
      select top 1 p.pkProductId
      from string_split(isai_d.ProductKeywords, '|') as kw
      join Common.Products as p
         on p.fkProductTypeId = 4
        and p.IsActive = 1
        and len(trim(kw.value)) >= 2
        and lower(p.ProductName) like lower('%' + trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
      where isai_d.ProductKeywords is not null
      group by p.pkProductId, p.ProductName
      order by count(*) desc, len(p.ProductName) asc, p.pkProductId asc
   ) as kw_match_nb
   outer apply (
      select top 1 pkProductId, ProductName
      from Common.Products
      where lower(ProductName) like lower('%' + trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + '%')
        and fkProductTypeId = 4
        and IsActive = 1
      order by len(ProductName) asc, pkProductId asc
   ) as sinp_nb
   outer apply (
      select top 1 pkProductId, ProductName
      from Common.Products
      where lower(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + ProductName + '%')
        and fkProductTypeId = 4
        and IsActive = 1
      order by len(ProductName) desc, pkProductId asc
   ) as pins_nb
   outer apply (
      select top 1 cpap_p.pkProductId
      from Common.ProductAliases as cpa
      join Common.Products as cpap_p
         on cpap_p.pkProductId = cpa.fkProductId
        and cpap_p.fkProductTypeId = 4
        and cpap_p.IsActive = 1
      where lower(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) like lower('%' + trim(cpa.ProductAlias) + '%')
        and cpa.IsActive = 1
      order by len(cpa.ProductAlias) asc, cpa.fkProductId asc
   ) as cpap_nb
   left outer join Common.Products as cphr_nb
      on (cphr_nb.pkProductId = coalesce(
            cp_nb.pkProductId, cpial_nb.pkProductId, kw_match_nb.pkProductId,
            sinp_nb.pkProductId, pins_nb.pkProductId, cpap_nb.pkProductId)
          and cphr_nb.IsActive = 1)
   where lower(trim(isai_d.ProductType)) = 'mixed drink'
     and isai_d.IsWellKnownMixedDrink = 1
     and not exists (select 1 from isai_bp as bp where bp.fkImportStagingId = isai_d.fkImportStagingId)
),

md_unknown as (
   select
      isai.fkImportStagingId
     ,isai.pkImportStagingAIId
     ,isai.ItemAsListed
     ,isai.ProductName
     ,cast(null as varchar(100))   as BrandResolved
     ,cast(null as int)            as fkRecommendedBrandId
     ,cast(null as int)            as fkDefaultProductId
     ,cast(null as int)            as fkRecommendedProductId
     ,cast(null as varchar(1000))  as InfProdName
   from isai_bp as isai
   where (lower(trim(isai.Brand)) = 'mixed drink' or lower(trim(isai.ProductType)) = 'mixed drink')
   and coalesce(isai.IsWellKnownMixedDrink, 0) = 0   -- 0=proprietary; NULL treated as unknown → unknown branch

   union all

   -- Null-brand items typed as Mixed Drink: isai_bp excludes rows where Brand is null,
   -- so these are not caught by the branch above. Route here for the same treatment
   -- (new_fkProductId=null/12257 per null guard, new_NewProductBrand=loc.Name, new_IsNewProduct=1).
   select
      isai_d.fkImportStagingId
     ,cast(null as int)            as pkImportStagingAIId
     ,isai_d.ItemAsListed
     ,isai_d.ProductName
     ,cast(null as varchar(100))   as BrandResolved
     ,cast(null as int)            as fkRecommendedBrandId
     ,cast(null as int)            as fkDefaultProductId
     ,cast(null as int)            as fkRecommendedProductId
     ,cast(null as varchar(1000))  as InfProdName
   from isai_dedup as isai_d
   where lower(trim(isai_d.ProductType)) = 'mixed drink'
     and coalesce(isai_d.IsWellKnownMixedDrink, 0) = 0
     and not exists (select 1 from isai_bp as bp where bp.fkImportStagingId = isai_d.fkImportStagingId)
),

no_brand_match as (
   -- Branch 4: No-brand fallback — items where the AI returned null
   -- or an unrecognized brand, and no mixed drink routing applied.
   -- Sources from isai_dedup (no Brand filter) and tries exact
   -- product name match across all brands as a last resort.
   select
      isai_d.fkImportStagingId
     ,isai_d_bp.pkImportStagingAIId
     ,isai_d.ItemAsListed
     ,isai_d.ProductName
     ,cast(null as varchar(100))  as BrandResolved
     ,cast(null as int)           as fkRecommendedBrandId
     ,cast(null as int)           as fkDefaultProductId
     ,coalesce(cp.pkProductId, cpial.pkProductId, sinp_nb.pkProductId) as fkRecommendedProductId
     ,cphr.ProductName            as InfProdName
   from isai_dedup as isai_d
   -- pkImportStagingAIId from isai_bp (NULL when Brand is null)
   left outer join isai_bp as isai_d_bp
      on isai_d_bp.fkImportStagingId = isai_d.fkImportStagingId
   -- Exact ProductName match across all brands (OUTER APPLY prevents fan-out)
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS))
        and p.IsActive = 1
      order by p.pkProductId asc
   ) as cp
   -- Exact ItemAsListed match across all brands
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where lower(p.ProductName) = lower(trim(isai_d.ItemAsListed collate SQL_Latin1_General_Cp1251_CS_AS))
        and p.IsActive = 1
      order by p.pkProductId asc
   ) as cpial
   -- Cross-brand sinp: catalog ProductName contains AI name as a whole word or phrase.
   -- Same direction as sinp_xbrand in product_match — the catalog has a longer name
   -- ('Generic Gin', 'Generic Hard Seltzer', 'Sauvignon Blanc Wine') while the AI
   -- writes the shorter base name ('Gin', 'Hard Seltzer', 'Sauvignon Blanc').
   -- Ordering prefers Generic brand then 'Generic X' names then shortest.
   outer apply (
      select top 1 p.pkProductId
      from Common.Products as p
      where (   lower(p.ProductName) like lower(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + ' %')
             or lower(p.ProductName) like lower('% ' + trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS) + ' %')
             or lower(p.ProductName) like lower('% ' + trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)))
        and p.IsActive = 1
        and len(trim(isai_d.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) >= 3
      order by
         case when p.fkBrandId = 2 then 0 else 1 end,
         case when lower(p.ProductName) like 'generic %' then 0 else 1 end,
         len(p.ProductName) asc,
         p.pkProductId asc
   ) as sinp_nb
   left outer join Common.Products as cphr
      on cphr.pkProductId = coalesce(cp.pkProductId, cpial.pkProductId, sinp_nb.pkProductId)
     and cphr.IsActive = 1
   -- Only items not already handled by brand_match, md_wellknown, or md_unknown
   where not exists (select 1 from brand_match  as bm where bm.fkImportStagingId = isai_d.fkImportStagingId)
   and   not exists (select 1 from md_wellknown as mw where mw.fkImportStagingId = isai_d.fkImportStagingId)
   and   not exists (select 1 from md_unknown   as mu where mu.fkImportStagingId = isai_d.fkImportStagingId)
   and   lower(trim(isai_d.ProductType)) <> 'mixed drink'
),

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

select

   tis.pkImportStagingId
  ,tis.TabDetailDescription

   -- --------------------------------------------------------
   -- fkProductId  (null when new_IsNewProduct = 1)
   -- --------------------------------------------------------
  ,case
      when cpt.pkProductTypeId in (5, 6, 7, 11)   then computed_prod.new_fkProductId   -- forced ID, skip null guard
      -- Generic mixed drink (Brand='Mixed Drink'): always use 12257 fallback, never null
      when (cpt.pkProductTypeId = 4 or lower(trim(isai_d.ProductType)) = 'mixed drink')
           and lower(trim(ibp.Brand)) = 'mixed drink'  then computed_prod.new_fkProductId
      when ss.fkRecommendedProductId is null        then null   -- new product (incl. unmatched brand-specific cocktails)
      else computed_prod.new_fkProductId
   end                                         as new_fkProductId
  ,case
      when cpt.pkProductTypeId in (5, 6, 7, 11)   then cp_new.ProductName
      when (cpt.pkProductTypeId = 4 or lower(trim(isai_d.ProductType)) = 'mixed drink')
           and lower(trim(ibp.Brand)) = 'mixed drink'  then cp_new.ProductName
      when ss.fkRecommendedProductId is null        then null
      else cp_new.ProductName
   end                                         as new_ProductName

   -- --------------------------------------------------------
   -- fkContainerId
   -- --------------------------------------------------------
  ,computed_cont.new_fkContainerId             as new_fkContainerId

   -- --------------------------------------------------------
   -- NewProductName
   -- --------------------------------------------------------
  ,case
      when cpt.pkProductTypeId = 6  or lower(trim(isai_d.ProductType)) in ('food','foods','food item','food & beverage','food and beverage')  then 'Generic Food'
      when cpt.pkProductTypeId = 11 or lower(trim(isai_d.ProductType)) in ('merch','merchandise','merchandising')                              then 'Generic Merch'
      when cpt.pkProductTypeId = 7  or lower(trim(isai_d.ProductType)) in ('misc','miscellaneous','other misc')                                then 'Miscellaneous'
      when cpt.pkProductTypeId = 5  or lower(trim(isai_d.ProductType)) in ('undefined','unknown','other','n/a','na','none')                    then 'Undefined'
      else isai_d.ProductName
   end                                         as new_NewProductName

   -- --------------------------------------------------------
   -- IsNewProduct
   -- --------------------------------------------------------
  ,case
      when cpt.pkProductTypeId in (5, 6, 7, 11)  then 0
      -- Generic mixed drinks use the 12257 fallback — never a new product to flag
      when (cpt.pkProductTypeId = 4 or lower(trim(isai_d.ProductType)) = 'mixed drink')
           and lower(trim(ibp.Brand)) = 'mixed drink'  then 0
      when ss.fkRecommendedProductId is null      then 1   -- no match (incl. unmatched brand-specific cocktails)
      else 0
   end                                         as new_IsNewProduct

   -- --------------------------------------------------------
   -- IsNewProductAlias
   -- --------------------------------------------------------
  ,case
      when cpt.pkProductTypeId in (5, 6, 7, 11)   then 0   -- fixed-type items; alias concept does not apply
      when ss.fkRecommendedProductId is null       then 0   -- no product found; flagged as new, not alias
      when lower(trim(ss.ProductName)) = lower(trim(ss.InfProdName)) then 0   -- exact match (case-insensitive, trimmed)
      else 1                                                -- product found but AI name differs from catalog name
   end                                         as new_IsNewProductAlias

   -- --------------------------------------------------------
   -- fkProductTypeId
   -- --------------------------------------------------------
  ,coalesce(cpt.pkProductTypeId, 5)             as new_fkProductTypeId   -- fallback: Undefined
  ,cpt.TypeDescription                         as new_ProductTypeDescription

   -- --------------------------------------------------------
   -- fkProductCategoryId
   -- --------------------------------------------------------
  ,cpc.pkProductCategoryId                     as new_fkProductCategoryId
  ,cpc.CategoryName                            as new_ProductCategoryName

   -- --------------------------------------------------------
   -- fkNewProductBrandId
   -- --------------------------------------------------------
  ,ss.fkRecommendedBrandId                     as new_fkNewProductBrandId
  ,cbr.BrandDescription                       as new_NewProductBrandDescription

   -- --------------------------------------------------------
   -- NewProductBrand
   -- Populated when IsNewProduct = 1 AND fkNewProductBrandId is NULL:
   -- captures the raw AI Brand string for items where no brand
   -- match exists in Common.Brands, so the brand is not lost.
   -- Fixed-type items and generic mixed drinks never set this.
   -- --------------------------------------------------------
  ,case
      when cpt.pkProductTypeId in (5, 6, 7, 11) then null
      -- Well-known mixed drink (IsWellKnownMixedDrink = 1) → resolved to catalog product, no text override needed
      when (cpt.pkProductTypeId = 4 or lower(trim(isai_d.ProductType)) = 'mixed drink')
           and isai_d.IsWellKnownMixedDrink = 1 then null
      -- Unknown/proprietary mixed drink (IsWellKnownMixedDrink = 0 or NULL) → use location name as brand display
      when (cpt.pkProductTypeId = 4 or lower(trim(isai_d.ProductType)) = 'mixed drink')
           and coalesce(isai_d.IsWellKnownMixedDrink, 0) = 0 then loc.Name
      when ss.fkRecommendedProductId is null and ss.fkRecommendedBrandId is null
         then ibp.Brand collate SQL_Latin1_General_Cp1251_CS_AS
      else null
   end                                         as new_NewProductBrand

from TabX.ImportStaging as tis

-- Deduplicated AI row for type/category/container fields (FK join — one row per tis row)
left outer join isai_dedup as isai_d
   on isai_d.fkImportStagingId = tis.pkImportStagingId

-- Raw brand value — needed to distinguish generic mixed drinks (Brand='Mixed Drink')
-- from brand-specific cocktails routed here via ProductType (e.g. 'Gray Whale Gin')
left outer join isai_bp as ibp
   on ibp.fkImportStagingId = tis.pkImportStagingId

-- Best brand+product match from all three branches (FK join — one row per tis row)
left outer join all_matches as ss
   on ss.fkImportStagingId = tis.pkImportStagingId

-- Resolve ProductType column → pkProductTypeId
-- Three-way match (priority order):
--   1. Exact equality
--   2. TypeDescription contains AI value  (AI is more specific: 'Seltzer' → 'RTD/Seltzer')
--   3. AI value contains TypeDescription  (AI is more verbose: 'Craft Beer' → 'Beer')
-- OUTER APPLY + TOP 1 prevents fan-out; exact match always wins.
outer apply (
   select top 1 pkProductTypeId, TypeDescription
   from Common.ProductTypes
   where IsActive = 1
     and trim(isai_d.ProductType) <> ''
     and (   lower(trim(TypeDescription)) = lower(trim(isai_d.ProductType))
          or lower(trim(TypeDescription)) like lower('%' + trim(isai_d.ProductType) + '%')
          or lower(trim(isai_d.ProductType)) like lower('%' + trim(TypeDescription) + '%'))
   order by
      case
         when lower(trim(TypeDescription)) = lower(trim(isai_d.ProductType))                      then 0
         when lower(trim(TypeDescription)) like lower('%' + trim(isai_d.ProductType) + '%')       then 1
         else 2
      end,
      len(TypeDescription) desc   -- among reverse-LIKE matches prefer the longest (most specific) TypeDescription
) as cpt

-- Resolve ProductCategory column → pkProductCategoryId.
-- Priority: exact → CategoryName contains AI value → AI value contains CategoryName.
-- Soft type-scope: prefer categories used by products of the resolved type (cpt) to
-- avoid cross-type false matches (e.g. 'Lager' hitting a wine category). Falls back
-- to any active category when no type-scoped match exists.
-- Tiebreaker differs by match direction:
--   forward-contains (CategoryName ⊇ AI value): shorter wins (more direct)
--   reverse-contains (AI value ⊇ CategoryName): longer wins (more specific)
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
            then len(pc.CategoryName)        -- forward-contains: shorter is more direct
         else 9999 - len(pc.CategoryName)    -- reverse-contains: longer is more specific (inverted asc)
      end,
      pc.pkProductCategoryId asc
) as cpc

left outer join Common.Brands as cbr
   on (cbr.pkBrandId = ss.fkRecommendedBrandId and cbr.IsActive = 1)

-- Compute new_fkProductId once so it can be joined to cp_new below
cross apply (values (
   case
      when cpt.pkProductTypeId = 6  then 12241
      when cpt.pkProductTypeId = 5  then 1
      when cpt.pkProductTypeId = 7  then 1
      when cpt.pkProductTypeId = 11 then 1
      when cpt.pkProductTypeId = 4 or lower(trim(isai_d.ProductType)) = 'mixed drink'
         then coalesce(ss.fkRecommendedProductId, 12257)
      when ss.fkRecommendedProductId is not null then ss.fkRecommendedProductId  -- product found (covers no-brand branch with cross-brand sinp match)
      when ss.fkRecommendedBrandId  is null then 1
      else cbr.fkDefaultProductId
   end
)) as computed_prod(new_fkProductId)

-- Compute new_fkContainerId once for clean display
cross apply (values (
   case
      when cpt.pkProductTypeId = 1  then
         case
            when lower(tis.TabDetailDescription) like '%bottle%'
              or ' ' + lower(tis.TabDetailDescription) + ' ' like '% bt %'
              or ' ' + lower(tis.TabDetailDescription) + ' ' like '% btl %' then 44
            when lower(tis.TabDetailDescription) like '%can%'   then 27
            else 12
         end
      when cpt.pkProductTypeId = 2  then
         case
            when lower(tis.TabDetailDescription) like '%dbl%'
              or lower(tis.TabDetailDescription) like '%double%' then 30
            else 26
         end
      when cpt.pkProductTypeId = 3  then
         case
            when lower(tis.TabDetailDescription) like '%bottle%'
              or ' ' + lower(tis.TabDetailDescription) + ' ' like '% bt %'
              or ' ' + lower(tis.TabDetailDescription) + ' ' like '% btl %' then 44
            else 33
         end
      when cpt.pkProductTypeId = 4  then 35
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
)) as computed_cont(new_fkContainerId)

-- Resolve new product name using the computed ID
left outer join Common.Products as cp_new
   on (cp_new.pkProductId = computed_prod.new_fkProductId and cp_new.IsActive = 1)

-- Location name — used for unknown proprietary mixed drinks (md_unknown branch).
left outer join TabX.Locations as loc
   on loc.pkLocationId = tis.fkLocationId

-- Only show rows where AI data exists for the item
where isai_d.fkImportStagingId is not null

order by tis.TabDetailDescription
GO
