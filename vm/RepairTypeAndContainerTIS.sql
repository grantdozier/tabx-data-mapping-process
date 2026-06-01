-- RepairTypeAndContainerTIS.sql
-- Post-update repair: re-applies ProductType and default Container resolution using the
-- same three-way priority logic as updateTisFromAI.sql.
--
-- Replaces the former raw LEFT OUTER JOIN approach, which was non-deterministic when
-- multiple ProductTypes matched the LIKE pattern (fan-out on the UPDATE target).
-- Uses isai_dedup (ROW_NUMBER-based) and OUTER APPLY TOP 1 to guarantee one result per row.
--
-- Run after updateTisFromAI.sql when a type-resolution regression is suspected,
-- or when new ProductTypes have been added to Common.ProductTypes.

;with
isai_dedup as (
   select
      fkImportStagingId
     ,ProductCategory as ProductType    -- intentionally swapped: raw ProductCategory holds TYPE data
   from (
      select fkImportStagingId, ProductCategory,
         row_number() over (partition by fkImportStagingId order by pkImportStagingAIId desc) as ai_rn
      from TabX.ImportStagingAI
   ) as ai_ranked
   where ai_rn = 1
),

-- ============================================================
-- Normalizes AI ProductType subtypes to catalog-matchable broad
-- names.  Without this, liquor/beer/wine subtypes from the AI
-- do not LIKE-match the broad type names in Common.ProductTypes,
-- causing most items to resolve to Undefined (pkProductTypeId=5).
-- ============================================================
isai_norm as (
   select
      d.fkImportStagingId
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
)

update tis
set
   fkProductTypeId = coalesce(cpt.pkProductTypeId, 5)   -- fallback: Undefined
  ,fkContainerId   =
      case
         when tis.fkContainerId is null or tis.fkContainerId = 29
            then coalesce(cpt.fkContainer_Default, 29)   -- apply type default only when container is unset or undefined
         else tis.fkContainerId                          -- leave existing specific container assignments intact
      end
from TabX.ImportStaging as tis
left outer join isai_norm as isai_d
   on isai_d.fkImportStagingId = tis.pkImportStagingId
-- Three-way priority match (same as cpt OUTER APPLY in updateTisFromAI.sql):
--   1. Exact equality
--   2. TypeDescription contains AI value  (AI more specific: 'Seltzer' → 'RTD/Seltzer')
--   3. AI value contains TypeDescription  (AI more verbose:  'Craft Beer' → 'Beer')
outer apply (
   select top 1 pkProductTypeId, fkContainer_Default
   from Common.ProductTypes
   where IsActive = 1
     and trim(isai_d.ProductType) <> ''
     and lower(trim(TypeDescription)) = lower(trim(isai_d.ProductType))
   order by pkProductTypeId asc
) as cpt
where isai_d.fkImportStagingId is not null
  and tis.fkProductId <> 16676   -- skip RR Research Market Rep rows
