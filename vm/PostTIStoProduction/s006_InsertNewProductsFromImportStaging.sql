-- s006_InsertNewProductsFromImportStaging.sql
--
-- When     Who   What
-- 20260309 auto  Created: insert new products identified by the AI classification pipeline.
--
-- Purpose:
--   Insert records into Common.Products for products that the AI classification pipeline
--   (updateTisFromAI.sql) could not resolve against Common.Products or Common.ProductAliases.
--   After insertion, backfills ImportStaging.fkProductId so downstream steps
--   (s010 onward) can link inventory records to the correct product.
--
-- Run order: AFTER s005_InsertNewBrandsFromImportStaging.sql, BEFORE s010.
--
-- FOUR SOURCE PATHS are processed:
--
-- PATH 1 — Regular new products (non-mixed-drink, non-non-alcoholic):
--   ImportStaging.IsNewProduct        = 1
--   ImportStaging.NewProductName     IS NOT NULL
--   ImportStaging.fkProductTypeId    IS NOT NULL, <> 4, <> @NonAlcoholicTypeId
--   ImportStaging.fkProductCategoryId IS NOT NULL
--   Product name source: ImportStaging.NewProductName
--   Brand:               ImportStaging.fkNewProductBrandId
--
-- PATH 2 — Mixed drink products (fkProductTypeId = 4):
--   ImportStaging.IsNewProduct        = 1
--   ImportStaging.fkProductTypeId    = 4
--   ImportStaging.fkProductCategoryId IS NOT NULL
--   ImportStagingAI.ProductName      IS NOT NULL
--   Product name source: ImportStagingAI.ProductName
--   Brand:               @GenericMixedDrinkBrandId ('Mixed Drink', or 'Undefined' as fallback)
--
-- PATH 3 — Non-alcoholic drink products:
--   ImportStaging.IsNewProduct        = 1
--   Identified by: ImportStaging.fkProductTypeId = @NonAlcoholicTypeId
--              OR: ImportStagingAI.ProductCategory = 'Non-Alcoholic Drink' (TYPE data,
--                  raw column; after column-swap compensation this is the type field)
--                  AND fkProductTypeId is not the mixed drink type (4)
--   ImportStagingAI.ProductName IS NOT NULL
--   Product name source: ImportStagingAI.ProductName
--   Brand:               ImportStaging.fkNewProductBrandId (not overridden)
--   fkProductTypeId:     Always @NonAlcoholicTypeId ('Non-Alcoholic Drink')
--   fkProductCategoryId: Always @NonAlcoholicCategoryId ('Generic Non-Alcoholic Drink')
--
-- PATH 4 — Catch-all (IsNewProduct=1 rows not inserted by paths 1–3):
--   ImportStaging.IsNewProduct        = 1
--   ImportStaging.fkProductId        IS NULL  (still unresolved after paths 1–3)
--   ImportStaging.fkProductTypeId    IS NOT NULL
--   ImportStaging.fkProductCategoryId IS NOT NULL
--   Product name source: ImportStaging.NewProductName, falling back to
--                         ImportStagingAI.ProductName if NewProductName is blank
--   Brand:               ImportStaging.fkNewProductBrandId (used as-is, no override)
--   Deduplication:       exact name match only — fuzzy rules are NOT applied.
--   Runs after paths 1–3 so Common.Products already contains any products they
--   just inserted; PATH 4's NOT EXISTS guard prevents conflicts.
--
-- Column swap note (ImportStagingAI):
--   The AI writes TYPE data into the ProductCategory column and CATEGORY data into
--   ProductType. PATH 3 text routing reads isai.ProductType for the
--   'Non-Alcoholic Drink' type check as it is the more reliable routing signal.
--
-- Deduplication:
--   After combining all three paths, rows are grouped by
--   (lower(trim(ProductName)), fkBrandId, fkProductTypeId) to preserve the correct
--   type and category for insertion. The dedup against Common.Products then uses
--   name-only matching so that existing products are found regardless of type/brand.
--
-- Deduplication against Common.Products:
--   Checks lower(trim(ProductName)) only — product names are globally unique in this
--   system. Type and brand are NOT used as dedup dimensions: a product named 'Sprite'
--   may exist under a different type (e.g. 'Soft Drink') and must still be recognised
--   as already present regardless of which type the AI assigned.
--   Also checks Common.ProductAliases.ProductAlias for name collisions.
--
-- SECTION 3 backfill:
--   PATH 1: updates IsNewProduct=1 rows with fkProductId IS NULL.
--   PATH 2 & 3: updates ALL qualifying rows regardless of current fkProductId, so any
--   generic fallback product assignment is replaced with the specific product.
--   PATH 4: updates any IsNewProduct=1 rows still with fkProductId IS NULL after
--   paths 1–3, using coalesce(NewProductName, isai.ProductName) for name lookup.
--
-- This script is safe to re-run. The INSERT deduplicates against Common.Products and
-- Common.ProductAliases. All four path UPDATEs are idempotent.
--
--use TabX
--GO


-- =========================================================================
-- SECTION 1: PREVIEW
-- Always safe to run. No data is modified.
-- Review this output before executing SECTION 2.
--
-- Key columns:
--   SourcePath             'Regular', 'Mixed Drink', or 'Non-Alcoholic Drink'
--   CandidateProductName   the product name that would be inserted
--   fkBrandId              resolved brand; Mixed Drink rows always show generic brand
--   BrandDescription       brand name for readability
--   fkProductTypeId        type FK used for insert
--   fkProductCategoryId    category FK used for insert
--   ABV                    parsed from ImportStagingAI.ABV; NULL if not parseable
--   AICity                 origin city from AI
--   FuzzyMatchInCatalog    existing product with a similar name (advisory; hard-blocked
--                          matches are suppressed here and shown in MatchingProduct instead)
--   SampleItems            example TabDetailDescriptions for context
--   SourceRowCount         number of ImportStaging rows generating this candidate
--   InsertStatus           whether this candidate will be inserted or skipped
--   MatchingProduct        the existing product/alias that caused a block (if any)
--   BatchDedupRank         rank among rows sharing the same product name in this batch;
--                          Section 2 inserts only rank-1. Rank > 1 rows are shown here
--                          for visibility but will NOT be inserted in Section 2.
-- =========================================================================

-- Resolve lookup values used throughout this batch.
declare @GenericMixedDrinkBrandId  int;
declare @NonAlcoholicTypeId        int;
declare @NonAlcoholicCategoryId    int;

select top 1 @GenericMixedDrinkBrandId = pkBrandId
from Common.Brands
where lower(trim(BrandDescription collate SQL_Latin1_General_Cp1251_CS_AS)) = 'mixed drink'
  and IsActive = 1
order by pkBrandId asc;

-- Fallback: if 'Mixed Drink' brand is absent, use 'Undefined' so PATH 2 rows still appear.
if @GenericMixedDrinkBrandId is null
   select top 1 @GenericMixedDrinkBrandId = pkBrandId
   from Common.Brands
   where lower(trim(BrandDescription collate SQL_Latin1_General_Cp1251_CS_AS)) = 'undefined'
     and IsActive = 1
   order by pkBrandId asc;

select top 1 @NonAlcoholicTypeId = pkProductTypeId
from Common.ProductTypes
where lower(trim(TypeDescription collate SQL_Latin1_General_Cp1251_CS_AS)) = 'non-alcoholic drink'
  and IsActive = 1
order by pkProductTypeId asc;

select top 1 @NonAlcoholicCategoryId = pkProductCategoryId
from Common.ProductCategories
where lower(trim(CategoryName collate SQL_Latin1_General_Cp1251_CS_AS)) = 'generic non-alcoholic drink'
  and IsActive = 1
order by pkProductCategoryId asc;

select
    @GenericMixedDrinkBrandId  as GenericMixedDrinkBrandId
   ,@NonAlcoholicTypeId        as NonAlcoholicTypeId
   ,@NonAlcoholicCategoryId    as NonAlcoholicCategoryId;

-- Guard: warn if any lookup failed. SECTION 2 will THROW on NULL; warn here so the
-- reviewer knows the preview results below may be incomplete before running SECTION 2.
-- Specifically: if @NonAlcoholicTypeId is NULL, PATH 1 returns 0 rows (NOT IN with NULL
-- evaluates UNKNOWN for every row), which silently hides all regular new products.
if @GenericMixedDrinkBrandId is null
   print 'WARNING: @GenericMixedDrinkBrandId is NULL — PATH 2 mixed drink rows will be missing. Ensure ''Mixed Drink'' or ''Undefined'' exists in Common.Brands.';
if @NonAlcoholicTypeId is null
   print 'WARNING: @NonAlcoholicTypeId is NULL — PATH 1 will return 0 rows and PATH 3 will be empty. Ensure ''Non-Alcoholic Drink'' exists in Common.ProductTypes.';
if @NonAlcoholicCategoryId is null
   print 'WARNING: @NonAlcoholicCategoryId is NULL — PATH 3 rows will be missing. Ensure ''Generic Non-Alcoholic Drink'' exists in Common.ProductCategories.';

; with

-- PATH 1: Regular new products. Excludes type-4 (PATH 2) and non-alcoholic (PATH 3).
regular_source as (
   select
      'Regular'                                                                     as SourcePath
     ,tis.pkImportStagingId
     ,tis.TabDetailDescription
     ,tis.fkProductTypeId
     ,tis.fkProductCategoryId
     ,tis.fkNewProductBrandId                                                       as fkBrandId
     ,nullif(trim(tis.NewProductName collate SQL_Latin1_General_Cp1251_CS_AS), '')  as ProductName
     ,try_convert(decimal(5,2),
         replace(nullif(trim(isai.ABV collate SQL_Latin1_General_Cp1251_CS_AS), ''), '%', '')
      )                                                                              as ABV
     ,nullif(trim(isai.City collate SQL_Latin1_General_Cp1251_CS_AS), '')           as AICity
     ,nullif(trim(isai.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS), '') as ProductKeywords
     ,tis.DateCreated
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProduct        = 1
     and tis.NewProductName      is not null
     and tis.fkProductTypeId     is not null
     and tis.fkProductTypeId     not in (4, @NonAlcoholicTypeId)
     and tis.fkProductCategoryId is not null
     -- Exclude rows the AI tagged as non-alcoholic via ProductCategory text, even if the
     -- type FK doesn't match @NonAlcoholicTypeId. Without this, those rows would appear
     -- in BOTH PATH 1 (under the AI-assigned type) and PATH 3 (@NonAlcoholicTypeId),
     -- producing two dedup groups and two inserted rows for the same product name.
     and coalesce(lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)), '') <> 'non-alcoholic drink'
),

-- PATH 2: Mixed drink products (fkProductTypeId = 4, IsNewProduct = 1). Always uses generic brand.
md_source as (
   select
      'Mixed Drink'                                                                 as SourcePath
     ,tis.pkImportStagingId
     ,tis.TabDetailDescription
     ,4                                                                             as fkProductTypeId
     ,tis.fkProductCategoryId
     ,@GenericMixedDrinkBrandId                                                    as fkBrandId
     ,nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '')   as ProductName
     ,try_convert(decimal(5,2),
         replace(nullif(trim(isai.ABV collate SQL_Latin1_General_Cp1251_CS_AS), ''), '%', '')
      )                                                                             as ABV
     ,nullif(trim(isai.City collate SQL_Latin1_General_Cp1251_CS_AS), '')          as AICity
     ,nullif(trim(isai.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS), '') as ProductKeywords
     ,tis.DateCreated
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProduct         = 1
     and tis.fkProductTypeId     = 4
     and tis.fkProductCategoryId is not null
     and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null
),

-- PATH 3: Non-alcoholic drink products (IsNewProduct = 1).
-- Identified by type FK or by isai.ProductType text ('Non-Alcoholic Drink').
-- Always inserts with @NonAlcoholicTypeId and @NonAlcoholicCategoryId.
na_source as (
   select
      'Non-Alcoholic Drink'                                                         as SourcePath
     ,tis.pkImportStagingId
     ,tis.TabDetailDescription
     ,@NonAlcoholicTypeId                                                            as fkProductTypeId
     ,@NonAlcoholicCategoryId                                                        as fkProductCategoryId
     ,tis.fkNewProductBrandId                                                        as fkBrandId
     ,nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '')    as ProductName
     ,try_convert(decimal(5,2),
         replace(nullif(trim(isai.ABV collate SQL_Latin1_General_Cp1251_CS_AS), ''), '%', '')
      )                                                                              as ABV
     ,nullif(trim(isai.City collate SQL_Latin1_General_Cp1251_CS_AS), '')           as AICity
     ,nullif(trim(isai.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS), '') as ProductKeywords
     ,tis.DateCreated
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProduct = 1
     and (
            tis.fkProductTypeId = @NonAlcoholicTypeId
         or (    lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)) = 'non-alcoholic drink'
             and coalesce(tis.fkProductTypeId, 0) <> 4)   -- type-4 rows belong to PATH 2
        )
     and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null
),

-- Combine all three paths, then deduplicate.
-- rn is used to limit SampleItems to 3 examples per candidate group.
source_rows as (
   select *
         ,row_number() over (
              partition by lower(trim(ProductName collate SQL_Latin1_General_Cp1251_CS_AS))
                          ,fkBrandId
                          ,fkProductTypeId
              order by pkImportStagingId
          ) as rn
   from (
      select * from regular_source
      union all
      select * from md_source
      union all
      select * from na_source
   ) as combined
),

-- Deduplicate to one candidate per (ProductName, fkBrandId, fkProductTypeId).
deduped as (
   select
      lower(trim(ProductName collate SQL_Latin1_General_Cp1251_CS_AS))   as ProductNameKey
     ,max(SourcePath)            as SourcePath
     ,max(ProductName)           as CandidateProductName
     ,max(fkBrandId)             as fkBrandId
     ,max(fkProductTypeId)       as fkProductTypeId
     ,max(fkProductCategoryId)   as fkProductCategoryId
     ,avg(ABV)                   as ABV
     ,max(AICity)                as AICity
     ,max(ProductKeywords)       as ProductKeywords
     ,min(DateCreated)           as EarliestImport
     ,count(*)                   as SourceRowCount
     ,string_agg(case when rn <= 3 then left(TabDetailDescription, 60) end, ' | ')
         within group (order by pkImportStagingId)    as SampleItems
   from source_rows
   where ProductName is not null
   group by lower(trim(ProductName collate SQL_Latin1_General_Cp1251_CS_AS))
           ,fkBrandId
           ,fkProductTypeId
),

-- Compute all display columns plus BatchDedupRank so the final SELECT can override
-- InsertStatus for same-name duplicates within this batch.
-- Section 2 inserts only rank-1 per ProductNameKey (ordered by fkProductTypeId asc, fkBrandId asc).
preview_data as (
   select
       d.ProductNameKey
      ,d.SourcePath
      ,d.CandidateProductName
      ,d.fkBrandId
      ,(
         select top 1 b.BrandDescription
         from Common.Brands as b
         where b.pkBrandId = d.fkBrandId
      )                             as BrandDescription
      ,d.fkProductTypeId
      ,d.fkProductCategoryId
      ,d.ABV
      ,d.AICity
      ,d.EarliestImport
      ,d.SourceRowCount
      ,(
         select top 1 p.ProductName
         from Common.Products as p
         where p.IsActive         = 1
           -- No type filter: non-alcoholic products may exist under a different type
           -- (e.g. 'Sprite' as 'Soft Drink'). Cross-type near-duplicates must surface here.
           and (   lower(p.ProductName) like lower('%' + d.CandidateProductName + '%')
                or lower(d.CandidateProductName) like lower('%' + trim(p.ProductName) + '%'))
           and lower(trim(p.ProductName)) <> d.ProductNameKey
           -- exclude hard-blocked match types — those surface in MatchingProduct instead
           and replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') <> replace(d.ProductNameKey, '''', '')  -- apostrophe
           and not (p.fkBrandId = d.fkBrandId                                                                                               -- reverse-fragment (same brand)
                    and len(lower(trim(p.ProductName))) >= 5
                    and d.ProductNameKey like '%' + replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') + '%')
           and not (len(lower(trim(p.ProductName))) >= 5                                                                                     -- word-prefix (any brand)
                    and d.ProductNameKey like replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') + ' %')
           and not (p.fkBrandId = d.fkBrandId                                                                                               -- brand-scoped word-bag
                    and 2 <= (select count(*) from string_split(replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', ''), ' ') where len(value) >= 3)
                    and not exists (
                        select 1
                        from string_split(replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', ''), ' ') as w
                        where len(w.value) >= 3
                          and replace(d.ProductNameKey, '''', '') not like '%' + w.value + '%'
                    ))
         order by len(p.ProductName) asc
      )                             as FuzzyMatchInCatalog
      ,d.SampleItems
      ,case
          -- Exact name match
          when exists (
              select 1 from Common.Products as p
              where lower(trim(p.ProductName)) = d.ProductNameKey
          ) then 'Already in Common.Products — will be skipped'
          -- Apostrophe-normalised match: "Baileys Irish Cream" ~ "Bailey's Irish Cream"
          when exists (
              select 1 from Common.Products as p
              where p.IsActive = 1
                and replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') = replace(d.ProductNameKey, '''', '')
                and lower(trim(p.ProductName)) <> d.ProductNameKey
          ) then 'Apostrophe variant of existing product — will be skipped'
          -- Reverse-fragment (same brand): existing product name is a substring of the candidate
          when exists (
              select 1 from Common.Products as p
              where p.IsActive = 1
                and p.fkBrandId = d.fkBrandId
                and len(lower(trim(p.ProductName))) >= 5
                and d.ProductNameKey like '%' + replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') + '%'
                and lower(trim(p.ProductName)) <> d.ProductNameKey
          ) then 'Existing product name contained in candidate (same brand) — will be skipped'
          -- Cross-brand word-prefix: existing name + space is the start of the candidate
          -- e.g. "Budweiser" blocks "Budweiser Lager" even when brand FKs differ
          when exists (
              select 1 from Common.Products as p
              where p.IsActive = 1
                and len(lower(trim(p.ProductName))) >= 5
                and d.ProductNameKey like replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') + ' %'
                and lower(trim(p.ProductName)) <> d.ProductNameKey
          ) then 'Existing product name is a prefix of candidate — will be skipped'
          -- Brand-scoped word-bag: all significant words of existing product appear in candidate
          when exists (
              select 1 from Common.Products as p
              where p.IsActive = 1
                and p.fkBrandId = d.fkBrandId
                and 2 <= (select count(*) from string_split(replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', ''), ' ') where len(value) >= 3)
                and not exists (
                    select 1
                    from string_split(replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', ''), ' ') as w
                    where len(w.value) >= 3
                      and replace(d.ProductNameKey, '''', '') not like '%' + w.value + '%'
                )
          ) then 'All words of existing product found in candidate (same brand) — will be skipped'
          -- Brand + keyword match: the candidate's own AI-assigned keywords all appear
          -- in an existing product name within the same brand.
          when exists (
              select 1 from Common.Products as p
              where p.fkBrandId = d.fkBrandId
                and p.IsActive  = 1
                and d.ProductKeywords is not null
                and exists (
                    select 1
                    from string_split(lower(trim(d.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS)), '|') as kw
                    where len(trim(kw.value)) >= 3
                )
                and not exists (
                    select 1
                    from string_split(lower(trim(d.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS)), '|') as kw
                    where len(trim(kw.value)) >= 3
                      and replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '')
                            not like '%' + replace(trim(kw.value), '''', '') + '%'
                )
          ) then 'Keyword match with existing product — will be skipped'
          -- Exact alias match
          when exists (
              select 1 from Common.ProductAliases as pa
              where lower(trim(pa.ProductAlias)) = d.ProductNameKey
          ) then 'Already in Common.ProductAliases — will be skipped'
          -- Apostrophe-normalised alias match
          when exists (
              select 1 from Common.ProductAliases as pa
              where replace(lower(trim(pa.ProductAlias collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') = replace(d.ProductNameKey, '''', '')
                and lower(trim(pa.ProductAlias)) <> d.ProductNameKey
          ) then 'Apostrophe variant of existing product alias — will be skipped'
          else 'NEW — will be inserted'
      end                           as InsertStatus
      ,(
         select top 1 match_name
         from (
            -- exact product name
            select p.ProductName as match_name, 1 as Priority
            from Common.Products as p
            where lower(trim(p.ProductName)) = d.ProductNameKey
            union all
            -- apostrophe-normalised product name
            select p.ProductName, 2
            from Common.Products as p
            where p.IsActive = 1
              and replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') = replace(d.ProductNameKey, '''', '')
              and lower(trim(p.ProductName)) <> d.ProductNameKey
            union all
            -- reverse-fragment: existing name is a substring of candidate, same brand
            select p.ProductName, 3
            from Common.Products as p
            where p.IsActive = 1
              and p.fkBrandId = d.fkBrandId
              and len(lower(trim(p.ProductName))) >= 5
              and d.ProductNameKey like '%' + replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') + '%'
              and lower(trim(p.ProductName)) <> d.ProductNameKey
            union all
            -- cross-brand word-prefix: existing name + space is the start of the candidate
            select p.ProductName, 4
            from Common.Products as p
            where p.IsActive = 1
              and len(lower(trim(p.ProductName))) >= 5
              and d.ProductNameKey like replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') + ' %'
              and lower(trim(p.ProductName)) <> d.ProductNameKey
            union all
            -- brand-scoped word-bag: all significant words of existing appear in candidate
            select p.ProductName, 5
            from Common.Products as p
            where p.IsActive = 1
              and p.fkBrandId = d.fkBrandId
              and 2 <= (select count(*) from string_split(replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', ''), ' ') where len(value) >= 3)
              and not exists (
                  select 1
                  from string_split(replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', ''), ' ') as w
                  where len(w.value) >= 3
                    and replace(d.ProductNameKey, '''', '') not like '%' + w.value + '%'
              )
            union all
            -- brand + keyword match: candidate's AI keywords all appear in an existing product name
            select p.ProductName, 6
            from Common.Products as p
            where p.fkBrandId = d.fkBrandId
              and p.IsActive  = 1
              and d.ProductKeywords is not null
              and exists (
                  select 1
                  from string_split(lower(trim(d.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS)), '|') as kw
                  where len(trim(kw.value)) >= 3
              )
              and not exists (
                  select 1
                  from string_split(lower(trim(d.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS)), '|') as kw
                  where len(trim(kw.value)) >= 3
                    and replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '')
                          not like '%' + replace(trim(kw.value), '''', '') + '%'
              )
            union all
            -- exact alias
            select pa.ProductAlias, 7
            from Common.ProductAliases as pa
            where lower(trim(pa.ProductAlias)) = d.ProductNameKey
            union all
            -- apostrophe-normalised alias
            select pa.ProductAlias, 8
            from Common.ProductAliases as pa
            where replace(lower(trim(pa.ProductAlias collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') = replace(d.ProductNameKey, '''', '')
              and lower(trim(pa.ProductAlias)) <> d.ProductNameKey
         ) as matches
         order by Priority
      )                             as MatchingProduct
   from deduped as d
),

-- Add NewBatchRank: counts only among NEW rows that share the same product name.
-- Non-NEW rows are excluded via CASE WHEN (they return NULL).
-- Implementation: NEW rows share a partition by ProductNameKey; non-NEW rows are
-- given a unique partition so they don't affect the ranking of NEW rows.
preview_ranked as (
   select
       pd.*
      ,case when pd.InsertStatus = 'NEW — will be inserted'
            then row_number() over (
                     partition by
                         -- NEW rows with the same name share one partition.
                         -- Non-NEW rows each get their own unique partition so they
                         -- cannot displace a NEW row from rank-1.
                         case when pd.InsertStatus = 'NEW — will be inserted'
                              then pd.ProductNameKey
                              else pd.ProductNameKey + '|||'
                                   + cast(pd.fkProductTypeId as varchar(10)) + '|||'
                                   + coalesce(cast(pd.fkBrandId as varchar(10)), 'null')
                         end
                     order by pd.fkProductTypeId asc
                             ,case when pd.fkBrandId is null then 1 else 0 end asc
                             ,pd.fkBrandId asc
                 )
            else null
       end                          as NewBatchRank
   from preview_data as pd
)

select
    pr.SourcePath
   ,pr.CandidateProductName
   ,pr.fkBrandId
   ,pr.BrandDescription
   ,pr.fkProductTypeId
   ,pr.fkProductCategoryId
   ,pr.ABV
   ,pr.AICity
   ,pr.EarliestImport
   ,pr.SourceRowCount
   ,pr.FuzzyMatchInCatalog
   ,pr.SampleItems
   -- For NEW rows sharing a name: only rank-1 will be inserted by Section 2.
   -- Rank is computed only among NEW rows — blocked rows don't affect it.
   ,case
       when pr.NewBatchRank > 1
           then 'Duplicate name in batch — rank-' + cast(pr.NewBatchRank as varchar(10))
                + ' row; Section 2 inserts only rank-1 (typeId=' + cast(pr.fkProductTypeId as varchar(10)) + ')'
       else pr.InsertStatus
    end                             as InsertStatus
   ,pr.MatchingProduct
   ,pr.NewBatchRank                 as BatchDedupRank
from preview_ranked as pr
order by pr.SourcePath, pr.fkProductTypeId, pr.CandidateProductName;
GO


-- =========================================================================
-- SECTION 1b: PREVIEW — PATH 4 catch-all candidates
-- Shows IsNewProduct=1 rows that are NOT handled by paths 1–3 and have a
-- resolvable product name. Rows qualifying for paths 1–3 are excluded here
-- (they appear in Section 1). PATH 4 in Section 2 inserts them using
-- exact-name dedup only — no fuzzy matching.
--
-- Columns:
--   CandidateProductName   name that will be inserted (NewProductName first,
--                          isai.ProductName as fallback)
--   BrandDescription       brand from ImportStaging.fkNewProductBrandId
--   InsertStatus           'NEW (catch-all) — will be inserted by PATH 4'
--                          or 'Already in Common.Products/Aliases — will be skipped'
--   SampleItems            up to 3 TabDetailDescriptions for identification
-- =========================================================================
declare @NonAlcoholicTypeId int;

select top 1 @NonAlcoholicTypeId = pkProductTypeId
from Common.ProductTypes
where lower(trim(TypeDescription collate SQL_Latin1_General_Cp1251_CS_AS)) = 'non-alcoholic drink'
  and IsActive = 1
order by pkProductTypeId asc;

; with path4_preview as (
   select
      tis.pkImportStagingId
     ,tis.fkProductTypeId
     ,tis.fkProductCategoryId
     ,tis.fkNewProductBrandId                                                          as fkBrandId
     ,coalesce(
         nullif(trim(tis.NewProductName collate SQL_Latin1_General_Cp1251_CS_AS), ''),
         nullif(trim(isai.ProductName   collate SQL_Latin1_General_Cp1251_CS_AS), '')
      )                                                                                as ProductName
     ,try_convert(decimal(5,2),
         replace(nullif(trim(isai.ABV collate SQL_Latin1_General_Cp1251_CS_AS), ''), '%', '')
      )                                                                                as ABV
     ,nullif(trim(isai.City collate SQL_Latin1_General_Cp1251_CS_AS), '')             as AICity
     ,tis.DateCreated
     ,tis.TabDetailDescription
     ,row_number() over (
          partition by coalesce(
              nullif(trim(tis.NewProductName collate SQL_Latin1_General_Cp1251_CS_AS), ''),
              nullif(trim(isai.ProductName   collate SQL_Latin1_General_Cp1251_CS_AS), ''))
          order by tis.pkImportStagingId
      ) as rn
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProduct        = 1
     and tis.fkProductId         is null
     and tis.fkProductTypeId     is not null
     and tis.fkProductCategoryId is not null
     -- Exclude rows that qualify for paths 1–3; those appear in Section 1 preview.
     -- At preview time fkProductId is always NULL, so we must exclude by source conditions
     -- rather than relying on the backfill that Section 3 performs at runtime.
     and not (
        -- PATH 1 (regular): non-type-4, non-non-alcoholic, NewProductName present
        (    tis.fkProductTypeId not in (4, @NonAlcoholicTypeId)
         and tis.NewProductName is not null
         and coalesce(lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)), '') <> 'non-alcoholic drink')
        or
        -- PATH 2 (mixed drink): type-4 with AI product name
        (    tis.fkProductTypeId = 4
         and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null)
        or
        -- PATH 3 (non-alcoholic): by type FK or AI text routing
        ((   tis.fkProductTypeId = @NonAlcoholicTypeId
          or (    lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)) = 'non-alcoholic drink'
              and coalesce(tis.fkProductTypeId, 0) <> 4))
         and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null)
     )
),
path4_deduped as (
   select
      lower(trim(ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) as ProductNameKey
     ,max(ProductName)         as CandidateProductName
     ,max(fkBrandId)           as fkBrandId
     ,max(fkProductTypeId)     as fkProductTypeId
     ,max(fkProductCategoryId) as fkProductCategoryId
     ,avg(ABV)                 as ABV
     ,max(AICity)              as AICity
     ,min(DateCreated)         as EarliestImport
     ,count(*)                 as SourceRowCount
     ,string_agg(case when rn <= 3 then left(TabDetailDescription, 60) end, ' | ')
         within group (order by pkImportStagingId) as SampleItems
   from path4_preview
   where ProductName is not null
   group by lower(trim(ProductName collate SQL_Latin1_General_Cp1251_CS_AS))
)
select
    d.CandidateProductName
   ,(select top 1 b.BrandDescription
     from Common.Brands as b
     where b.pkBrandId = d.fkBrandId)  as BrandDescription
   ,d.fkBrandId
   ,d.fkProductTypeId
   ,d.fkProductCategoryId
   ,d.ABV
   ,d.AICity
   ,d.EarliestImport
   ,d.SourceRowCount
   ,d.SampleItems
   ,case
       when exists (select 1 from Common.Products as p
                    where lower(trim(p.ProductName)) = d.ProductNameKey)
           then 'Already in Common.Products — will be skipped'
       when exists (select 1 from Common.ProductAliases as pa
                    where lower(trim(pa.ProductAlias)) = d.ProductNameKey)
           then 'Already in Common.ProductAliases — will be skipped'
       else 'NEW (catch-all) — will be inserted by PATH 4'
    end                        as InsertStatus
from path4_deduped as d
order by d.CandidateProductName;
GO

/*

-- =========================================================================
-- SECTION 2: INSERT new products + SECTION 3: UPDATE ImportStaging
--
-- Review SECTION 1 output before running this block.
-- Both steps run inside a single transaction.
-- =========================================================================
BEGIN TRANSACTION;
BEGIN TRY

   declare @GenericMixedDrinkBrandId  int;
   declare @NonAlcoholicTypeId        int;
   declare @NonAlcoholicCategoryId    int;

   select top 1 @GenericMixedDrinkBrandId = pkBrandId
   from Common.Brands
   where lower(trim(BrandDescription collate SQL_Latin1_General_Cp1251_CS_AS)) = 'mixed drink'
     and IsActive = 1
   order by pkBrandId asc;

   select top 1 @NonAlcoholicTypeId = pkProductTypeId
   from Common.ProductTypes
   where lower(trim(TypeDescription collate SQL_Latin1_General_Cp1251_CS_AS)) = 'non-alcoholic drink'
     and IsActive = 1
   order by pkProductTypeId asc;

   select top 1 @NonAlcoholicCategoryId = pkProductCategoryId
   from Common.ProductCategories
   where lower(trim(CategoryName collate SQL_Latin1_General_Cp1251_CS_AS)) = 'generic non-alcoholic drink'
     and IsActive = 1
   order by pkProductCategoryId asc;

   if @GenericMixedDrinkBrandId is null
   begin
      select top 1 @GenericMixedDrinkBrandId = pkBrandId
      from Common.Brands
      where lower(trim(BrandDescription collate SQL_Latin1_General_Cp1251_CS_AS)) = 'undefined'
        and IsActive = 1
      order by pkBrandId asc;

      if @GenericMixedDrinkBrandId is null
         throw 50006, 'Cannot resolve generic Mixed Drink brand or Undefined fallback. Ensure ''Mixed Drink'' or ''Undefined'' exists and is active in Common.Brands.', 1;

      print 'WARNING: ''Mixed Drink'' brand not found — mixed drink products will be assigned to the ''Undefined'' brand.';
   end

   if @NonAlcoholicTypeId is null
      throw 50007, 'Cannot resolve Non-Alcoholic Drink product type. Ensure ''Non-Alcoholic Drink'' exists and is active in Common.ProductTypes.', 1;

   if @NonAlcoholicCategoryId is null
      throw 50008, 'Cannot resolve Generic Non-Alcoholic Drink category. Ensure ''Generic Non-Alcoholic Drink'' exists and is active in Common.ProductCategories.', 1;

   -- -----------------------------------------------------------------------
   -- SECTION 2: Insert new products into Common.Products
   -- -----------------------------------------------------------------------
   ; with

   regular_source as (
      select
         tis.pkImportStagingId
        ,tis.fkProductTypeId
        ,tis.fkProductCategoryId
        ,tis.fkNewProductBrandId                                                       as fkBrandId
        ,nullif(trim(tis.NewProductName collate SQL_Latin1_General_Cp1251_CS_AS), '')  as ProductName
        ,try_convert(decimal(5,2),
            replace(nullif(trim(isai.ABV collate SQL_Latin1_General_Cp1251_CS_AS), ''), '%', '')
         )                                                                              as ABV
        ,nullif(trim(isai.City collate SQL_Latin1_General_Cp1251_CS_AS), '')           as AICity
        ,nullif(trim(isai.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS), '') as ProductKeywords
        ,tis.DateCreated
      from TabX.ImportStaging as tis
      inner join TabX.ImportStagingAI as isai
         on isai.fkImportStagingId = tis.pkImportStagingId
      where tis.IsNewProduct        = 1
        and tis.NewProductName      is not null
        and tis.fkProductTypeId     is not null
        and tis.fkProductTypeId     not in (4, @NonAlcoholicTypeId)
        and tis.fkProductCategoryId is not null
        -- Exclude rows the AI tagged as non-alcoholic via ProductCategory text — same
        -- guard as SECTION 1 to prevent PATH 1 / PATH 3 overlap and duplicate insertion.
        and coalesce(lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)), '') <> 'non-alcoholic drink'
   ),

   md_source as (
      select
         tis.pkImportStagingId
        ,4                                                                             as fkProductTypeId
        ,tis.fkProductCategoryId
        ,@GenericMixedDrinkBrandId                                                    as fkBrandId
        ,nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '')   as ProductName
        ,try_convert(decimal(5,2),
            replace(nullif(trim(isai.ABV collate SQL_Latin1_General_Cp1251_CS_AS), ''), '%', '')
         )                                                                             as ABV
        ,nullif(trim(isai.City collate SQL_Latin1_General_Cp1251_CS_AS), '')          as AICity
        ,nullif(trim(isai.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS), '') as ProductKeywords
        ,tis.DateCreated
      from TabX.ImportStaging as tis
      inner join TabX.ImportStagingAI as isai
         on isai.fkImportStagingId = tis.pkImportStagingId
      where tis.IsNewProduct         = 1
        and tis.fkProductTypeId     = 4
        and tis.fkProductCategoryId is not null
        and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null
   ),

   na_source as (
      select
         tis.pkImportStagingId
        ,@NonAlcoholicTypeId                                                            as fkProductTypeId
        ,@NonAlcoholicCategoryId                                                        as fkProductCategoryId
        ,tis.fkNewProductBrandId                                                        as fkBrandId
        ,nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '')    as ProductName
        ,try_convert(decimal(5,2),
            replace(nullif(trim(isai.ABV collate SQL_Latin1_General_Cp1251_CS_AS), ''), '%', '')
         )                                                                              as ABV
        ,nullif(trim(isai.City collate SQL_Latin1_General_Cp1251_CS_AS), '')           as AICity
        ,nullif(trim(isai.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS), '') as ProductKeywords
        ,tis.DateCreated
      from TabX.ImportStaging as tis
      inner join TabX.ImportStagingAI as isai
         on isai.fkImportStagingId = tis.pkImportStagingId
      where tis.IsNewProduct = 1
        and (
               tis.fkProductTypeId = @NonAlcoholicTypeId
            or (    lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)) = 'non-alcoholic drink'
                and coalesce(tis.fkProductTypeId, 0) <> 4)
           )
        and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null
   ),

   source_rows as (
      select * from regular_source
      union all
      select * from md_source
      union all
      select * from na_source
   ),

   deduped as (
      select
         lower(trim(ProductName collate SQL_Latin1_General_Cp1251_CS_AS))   as ProductNameKey
        ,max(ProductName)           as ProductName
        ,fkBrandId
        ,fkProductTypeId
        ,max(fkProductCategoryId)   as fkProductCategoryId
        ,avg(ABV)                   as ABV
        ,max(AICity)                as OriginCity
        ,max(ProductKeywords)       as ProductKeywords
        ,min(DateCreated)           as DateCreated
      from source_rows
      where ProductName is not null
      group by lower(trim(ProductName collate SQL_Latin1_General_Cp1251_CS_AS))
              ,fkBrandId
              ,fkProductTypeId
   ),

   new_products as (
      select d.ProductNameKey, d.ProductName, d.fkBrandId, d.fkProductTypeId,
             d.fkProductCategoryId, d.ABV, d.OriginCity, d.DateCreated
      from (
          select d.*
                ,row_number() over (
                     partition by d.ProductNameKey
                     -- Prefer non-null brand; NULLs sort first in SQL Server ASC,
                     -- so push them to the end with an explicit null-last expression.
                     order by d.fkProductTypeId asc
                             ,case when d.fkBrandId is null then 1 else 0 end asc
                             ,d.fkBrandId asc
                 ) as dup_rn
          from deduped as d
          -- Name-only match: product names are globally unique; type/brand not checked here
          -- because 'Sprite' stored as 'Soft Drink' must still be recognised as present.
          where not exists (
              select 1 from Common.Products as p
              where lower(trim(p.ProductName)) = d.ProductNameKey
                 -- apostrophe-normalised match: "Baileys Irish Cream" = "Bailey's Irish Cream"
                 or (p.IsActive = 1
                     and replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') = replace(d.ProductNameKey, '''', '')
                     and lower(trim(p.ProductName)) <> d.ProductNameKey)
                 -- reverse-fragment (same brand): existing name is a substring of the candidate
                 -- e.g. "Corona Extra" blocks "Corona Extra Lager"; "Aperol" blocks "Aperol Aperitivo"
                 or (p.IsActive = 1
                     and p.fkBrandId = d.fkBrandId
                     and len(lower(trim(p.ProductName))) >= 5
                     and d.ProductNameKey like '%' + replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') + '%'
                     and lower(trim(p.ProductName)) <> d.ProductNameKey)
                 -- cross-brand word-prefix: existing name + space is the start of the candidate
                 -- e.g. "Budweiser" blocks "Budweiser Lager" even when brand FKs differ
                 or (p.IsActive = 1
                     and len(lower(trim(p.ProductName))) >= 5
                     and d.ProductNameKey like replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') + ' %'
                     and lower(trim(p.ProductName)) <> d.ProductNameKey)
                 -- brand-scoped word-bag: all significant words (>=3 chars) of the existing
                 -- product name appear in the candidate name (>=2 such words required).
                 -- e.g. "Bailey's Irish Cream" blocks "Baileys Original Irish Cream"
                 or (p.IsActive = 1
                     and p.fkBrandId = d.fkBrandId
                     and 2 <= (select count(*) from string_split(replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', ''), ' ') where len(value) >= 3)
                     and not exists (
                         select 1
                         from string_split(replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', ''), ' ') as w
                         where len(w.value) >= 3
                           and replace(d.ProductNameKey, '''', '') not like '%' + w.value + '%'
                     ))
          )
          -- Brand + keyword match: the candidate's own AI-assigned keywords (from ImportStagingAI)
          -- all appear in an existing product name within the same brand.
          and not exists (
              select 1 from Common.Products as p
              where p.fkBrandId = d.fkBrandId
                and p.IsActive  = 1
                and d.ProductKeywords is not null
                -- at least one keyword long enough to be meaningful
                and exists (
                    select 1
                    from string_split(lower(trim(d.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS)), '|') as kw
                    where len(trim(kw.value)) >= 3
                )
                -- all significant keywords appear in the existing product name
                -- (apostrophe-normalised on both sides: "bailey's" matches keyword "baileys")
                and not exists (
                    select 1
                    from string_split(lower(trim(d.ProductKeywords collate SQL_Latin1_General_Cp1251_CS_AS)), '|') as kw
                    where len(trim(kw.value)) >= 3
                      and replace(lower(trim(p.ProductName collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '')
                            not like '%' + replace(trim(kw.value), '''', '') + '%'
                )
          )
          and not exists (
              select 1 from Common.ProductAliases as pa
              where lower(trim(pa.ProductAlias)) = d.ProductNameKey
                 -- apostrophe-normalised alias match
                 or (replace(lower(trim(pa.ProductAlias collate SQL_Latin1_General_Cp1251_CS_AS)), '''', '') = replace(d.ProductNameKey, '''', '')
                     and lower(trim(pa.ProductAlias)) <> d.ProductNameKey)
          )
      ) as d
      -- If the same product name appears across multiple dedup groups (different brand/type),
      -- take only one row to prevent duplicate-name inserts.
      where d.dup_rn = 1
   )

   insert into Common.Products
          (fkBrandId
          ,fkProductTypeId
          ,fkProductCategoryId
          ,ProductName
          ,ABV
          ,OriginCity
          ,fkOriginCountryId
          ,fkOriginStateProvinceId
          ,IsActive
          ,fkCreatedByUserId
          ,DateCreated
          ,fkModifiedByUserId
          ,DateModified
          )
   select
       fkBrandId
      ,fkProductTypeId
      ,fkProductCategoryId
      ,ProductName
      ,ABV
      ,OriginCity
      ,null                     as fkOriginCountryId
      ,null                     as fkOriginStateProvinceId
      ,1                        as IsActive
      ,1                        as fkCreatedByUserId
      ,DateCreated
      ,1                        as fkModifiedByUserId
      ,DateCreated              as DateModified
   from new_products;

   declare @ProductsInserted int = @@rowcount;
   print concat('Section 2: ', @ProductsInserted, ' new product(s) inserted into Common.Products.');


   -- -----------------------------------------------------------------------
   -- PATH 4: Catch-all insert for IsNewProduct=1 rows still unresolved
   --
   -- Runs after the paths 1–3 INSERT so Common.Products already contains any
   -- products they just inserted. Uses coalesce(NewProductName, isai.ProductName)
   -- for the product name and fkNewProductBrandId as-is. Deduplicates by exact
   -- name only — fuzzy rules are not applied.
   -- -----------------------------------------------------------------------
   ; with path4_source as (
      select
         tis.pkImportStagingId
        ,tis.fkProductTypeId
        ,tis.fkProductCategoryId
        ,tis.fkNewProductBrandId                                                          as fkBrandId
        ,coalesce(
            nullif(trim(tis.NewProductName collate SQL_Latin1_General_Cp1251_CS_AS), ''),
            nullif(trim(isai.ProductName   collate SQL_Latin1_General_Cp1251_CS_AS), '')
         )                                                                                as ProductName
        ,try_convert(decimal(5,2),
            replace(nullif(trim(isai.ABV collate SQL_Latin1_General_Cp1251_CS_AS), ''), '%', '')
         )                                                                                as ABV
        ,nullif(trim(isai.City collate SQL_Latin1_General_Cp1251_CS_AS), '')             as OriginCity
        ,tis.DateCreated
      from TabX.ImportStaging as tis
      inner join TabX.ImportStagingAI as isai
         on isai.fkImportStagingId = tis.pkImportStagingId
      where tis.IsNewProduct        = 1
        and tis.fkProductId         is null
        and tis.fkProductTypeId     is not null
        and tis.fkProductCategoryId is not null
   ),
   path4_deduped as (
      select
         lower(trim(ProductName collate SQL_Latin1_General_Cp1251_CS_AS)) as ProductNameKey
        ,max(ProductName)         as ProductName
        ,max(fkBrandId)           as fkBrandId
        ,max(fkProductTypeId)     as fkProductTypeId
        ,max(fkProductCategoryId) as fkProductCategoryId
        ,avg(ABV)                 as ABV
        ,max(OriginCity)          as OriginCity
        ,min(DateCreated)         as DateCreated
      from path4_source
      where ProductName is not null
      group by lower(trim(ProductName collate SQL_Latin1_General_Cp1251_CS_AS))
   )
   insert into Common.Products
          (fkBrandId
          ,fkProductTypeId
          ,fkProductCategoryId
          ,ProductName
          ,ABV
          ,OriginCity
          ,fkOriginCountryId
          ,fkOriginStateProvinceId
          ,IsActive
          ,fkCreatedByUserId
          ,DateCreated
          ,fkModifiedByUserId
          ,DateModified
          )
   select
       d.fkBrandId
      ,d.fkProductTypeId
      ,d.fkProductCategoryId
      ,d.ProductName
      ,d.ABV
      ,d.OriginCity
      ,null                     as fkOriginCountryId
      ,null                     as fkOriginStateProvinceId
      ,1                        as IsActive
      ,1                        as fkCreatedByUserId
      ,d.DateCreated
      ,1                        as fkModifiedByUserId
      ,d.DateCreated            as DateModified
   from path4_deduped as d
   where not exists (
       select 1 from Common.Products as p
       where lower(trim(p.ProductName)) = d.ProductNameKey
   )
   and not exists (
       select 1 from Common.ProductAliases as pa
       where lower(trim(pa.ProductAlias)) = d.ProductNameKey
   );

   declare @Path4Inserted int = @@rowcount;
   print concat('Path 4: ', @Path4Inserted, ' catch-all product(s) inserted into Common.Products.');


   -- -----------------------------------------------------------------------
   -- SECTION 3: Backfill ImportStaging.fkProductId
   --
   -- PATH 1: IsNewProduct=1, type not 4 or non-alcoholic.
   --         Name from tis.NewProductName.
   -- PATH 2: IsNewProduct=1 type-4 rows. Name from isai.ProductName.
   -- PATH 3: IsNewProduct=1 non-alcoholic rows (by FK or by text).
   --         Name from isai.ProductName.
   -- PATH 4: handled by a separate UPDATE below; uses coalesce(NewProductName,
   --         isai.ProductName) to match what the PATH 4 INSERT just created.
   -- -----------------------------------------------------------------------
   update tis
   set    tis.fkProductId = prod_res.pkProductId
   from TabX.ImportStaging as tis
   left outer join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   -- Resolve the effective product type (handles text-routed non-alcoholic rows where
   -- fkProductTypeId may be NULL).
   outer apply (
      select case
         when tis.fkProductTypeId is not null then tis.fkProductTypeId
         when lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)) = 'non-alcoholic drink'
              then @NonAlcoholicTypeId
         else null
      end as ResolvedTypeId
   ) as type_res
   -- Resolve the product name: PATH 2 & 3 use isai.ProductName; PATH 1 uses NewProductName.
   outer apply (
      select lower(trim(
         case when tis.fkProductTypeId = 4
                   or type_res.ResolvedTypeId = @NonAlcoholicTypeId
              then nullif(trim(isai.ProductName  collate SQL_Latin1_General_Cp1251_CS_AS), '')
              else nullif(trim(tis.NewProductName collate SQL_Latin1_General_Cp1251_CS_AS), '')
         end collate SQL_Latin1_General_Cp1251_CS_AS
      )) as ProductNameKey
   ) as name_res
   -- Look up product by name: Products first, then ProductAliases as fallback.
   -- Product names are globally unique; type/brand not checked because 'Sprite' stored
   -- as 'Soft Drink' must still resolve correctly.
   outer apply (
      select top 1 pkProductId
      from (
         select p.pkProductId, 1 as Priority
         from Common.Products as p
         where p.IsActive = 1
           and lower(trim(p.ProductName)) = name_res.ProductNameKey
         union all
         select pa.fkProductId as pkProductId, 2 as Priority
         from Common.ProductAliases as pa
         where lower(trim(pa.ProductAlias)) = name_res.ProductNameKey
      ) as matches
      order by Priority
   ) as prod_res
   where type_res.ResolvedTypeId is not null
     and (
        -- PATH 1: regular new products — only update rows not yet resolved
        (   tis.IsNewProduct    = 1
        and tis.fkProductId     is null
        and tis.fkProductTypeId is not null
        and tis.fkProductTypeId not in (4, @NonAlcoholicTypeId)
        -- Exclude text-routed non-alcoholic rows; they belong to PATH 3.
        and coalesce(lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)), '') <> 'non-alcoholic drink')
        or
        -- PATH 2: mixed drinks — update all rows (replaces any prior fallback assignment)
        (   tis.IsNewProduct    = 1
        and tis.fkProductTypeId = 4)
        or
        -- PATH 3: non-alcoholic — update all rows (by FK or text routing)
        (   tis.IsNewProduct = 1
        and (   tis.fkProductTypeId = @NonAlcoholicTypeId
             or (    lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)) = 'non-alcoholic drink'
                 and coalesce(tis.fkProductTypeId, 0) <> 4)))
     )
     and name_res.ProductNameKey is not null
     and prod_res.pkProductId    is not null;

   declare @TisUpdated int = @@rowcount;
   print concat('Section 3: ', @TisUpdated, ' ImportStaging row(s) updated with fkProductId.');


   -- -----------------------------------------------------------------------
   -- PATH 4 backfill: update any IsNewProduct=1 rows still with fkProductId IS NULL.
   -- Uses coalesce(NewProductName, isai.ProductName) — mirrors the PATH 4 INSERT
   -- name resolution — so it correctly matches whatever PATH 4 just inserted.
   -- -----------------------------------------------------------------------
   update tis
   set    tis.fkProductId = prod_res.pkProductId
   from TabX.ImportStaging as tis
   left outer join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   outer apply (
      select lower(trim(coalesce(
         nullif(trim(tis.NewProductName collate SQL_Latin1_General_Cp1251_CS_AS), ''),
         nullif(trim(isai.ProductName   collate SQL_Latin1_General_Cp1251_CS_AS), '')
      ) collate SQL_Latin1_General_Cp1251_CS_AS)) as ProductNameKey
   ) as name_res
   outer apply (
      select top 1 pkProductId
      from (
         select p.pkProductId, 1 as Priority
         from Common.Products as p
         where p.IsActive = 1
           and lower(trim(p.ProductName)) = name_res.ProductNameKey
         union all
         select pa.fkProductId as pkProductId, 2 as Priority
         from Common.ProductAliases as pa
         where lower(trim(pa.ProductAlias)) = name_res.ProductNameKey
      ) as matches
      order by Priority
   ) as prod_res
   where tis.IsNewProduct        = 1
     and tis.fkProductId         is null
     and tis.fkProductTypeId     is not null
     and tis.fkProductCategoryId is not null
     and name_res.ProductNameKey is not null
     and prod_res.pkProductId    is not null;

   declare @Path4TisUpdated int = @@rowcount;
   print concat('Path 4: ', @Path4TisUpdated, ' ImportStaging row(s) updated with fkProductId (catch-all backfill).');


   -- -----------------------------------------------------------------------
   -- Post-run checks
   -- -----------------------------------------------------------------------

   -- Check 1: PATH 1 (regular) rows still with fkProductId=NULL.
   -- Mirrors PATH 1 INSERT filter: excludes type-4, non-alcoholic FK, and text-routed NA rows.
   declare @StillUnresolved int;
   select @StillUnresolved = count(*)
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProduct        = 1
     and tis.fkProductId         is null
     and tis.NewProductName      is not null
     and tis.fkProductTypeId     is not null
     and tis.fkProductTypeId     not in (4, @NonAlcoholicTypeId)
     and tis.fkProductCategoryId is not null
     -- Exclude text-routed non-alcoholic rows (handled by PATH 3, not PATH 1).
     and coalesce(lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)), '') <> 'non-alcoholic drink';

   if @StillUnresolved > 0
      print concat('WARNING: ', @StillUnresolved,
                   ' regular IsNewProduct=1 row(s) still have fkProductId=NULL. ',
                   'Run the SECTION 1 preview to investigate.');
   else
      print 'Post-run check 1: OK — no unresolved regular new product rows remain.';

   -- Check 2: PATH 2 (mixed drink) rows still with fkProductId=NULL.
   declare @MdStillUnresolved int;
   select @MdStillUnresolved = count(*)
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProduct    = 1
     and tis.fkProductTypeId = 4
     and tis.fkProductId     is null
     and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null;

   if @MdStillUnresolved > 0
      print concat('WARNING: ', @MdStillUnresolved,
                   ' mixed drink row(s) still have fkProductId=NULL. ',
                   'Run the SECTION 1 preview to investigate.');
   else
      print 'Post-run check 2: OK — no unresolved mixed drink rows remain.';

   -- Check 3: PATH 3 (non-alcoholic) rows still with fkProductId=NULL.
   declare @NaStillUnresolved int;
   select @NaStillUnresolved = count(*)
   from TabX.ImportStaging as tis
   inner join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProduct = 1
     and (   tis.fkProductTypeId = @NonAlcoholicTypeId
          or (    lower(trim(isai.ProductType collate SQL_Latin1_General_Cp1251_CS_AS)) = 'non-alcoholic drink'
              and coalesce(tis.fkProductTypeId, 0) <> 4))
     and tis.fkProductId is null
     and nullif(trim(isai.ProductName collate SQL_Latin1_General_Cp1251_CS_AS), '') is not null;

   if @NaStillUnresolved > 0
      print concat('WARNING: ', @NaStillUnresolved,
                   ' non-alcoholic drink row(s) still have fkProductId=NULL. ',
                   'Run the SECTION 1 preview to investigate.');
   else
      print 'Post-run check 3: OK — no unresolved non-alcoholic drink rows remain.';

   -- Check 4: IsNewProduct=1 rows skipped due to missing fkProductTypeId or fkProductCategoryId.
   declare @MissingTypeOrCat int;
   select @MissingTypeOrCat = count(*)
   from TabX.ImportStaging
   where IsNewProduct    = 1
     and fkProductId     is null
     and NewProductName  is not null
     and (fkProductTypeId is null or fkProductCategoryId is null);

   if @MissingTypeOrCat > 0
      print concat('WARNING: ', @MissingTypeOrCat,
                   ' IsNewProduct=1 row(s) skipped because fkProductTypeId or fkProductCategoryId ',
                   'is NULL. Correct these in ImportStaging and re-run.');
   else
      print 'Post-run check 4: OK — no rows missing fkProductTypeId or fkProductCategoryId.';

   -- Check 5: type-4 rows with NULL fkProductCategoryId — silently excluded from PATH 2
   -- (the md_source WHERE requires fkProductCategoryId IS NOT NULL). These rows are never
   -- processed by any path and will remain with fkProductId = NULL.
   declare @MdNullCategory int;
   select @MdNullCategory = count(*)
   from TabX.ImportStaging
   where fkProductTypeId    = 4
     and fkProductCategoryId is null;

   if @MdNullCategory > 0
      print concat('WARNING: ', @MdNullCategory,
                   ' mixed drink row(s) were skipped because fkProductCategoryId is NULL. ',
                   'Set fkProductCategoryId on these ImportStaging rows and re-run.');
   else
      print 'Post-run check 5: OK — no type-4 rows with NULL fkProductCategoryId.';

   -- Check 6: Any IsNewProduct=1 rows still unresolved after all four paths.
   -- PATH 4 catches everything with a non-null type, category, and name, so a
   -- non-zero result here means the row is missing fkProductTypeId, fkProductCategoryId,
   -- or both NewProductName and isai.ProductName — none of which PATH 4 can fill in.
   declare @Path4StillUnresolved int;
   select @Path4StillUnresolved = count(*)
   from TabX.ImportStaging as tis
   left outer join TabX.ImportStagingAI as isai
      on isai.fkImportStagingId = tis.pkImportStagingId
   where tis.IsNewProduct = 1
     and tis.fkProductId  is null;

   if @Path4StillUnresolved > 0
      print concat('WARNING: ', @Path4StillUnresolved,
                   ' IsNewProduct=1 row(s) still have fkProductId=NULL after all four paths. ',
                   'These rows are missing fkProductTypeId, fkProductCategoryId, or a product name. ',
                   'Run Section 1b preview to investigate.');
   else
      print 'Post-run check 6: OK — all IsNewProduct=1 rows resolved.';


   COMMIT TRANSACTION;

END TRY
BEGIN CATCH
   ROLLBACK TRANSACTION;
   THROW;
END CATCH
GO

*/

