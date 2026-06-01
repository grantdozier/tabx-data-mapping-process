-- diagKwMatch27429.sql
-- Diagnoses why kwMatchProducts.sql chose a specific product for
-- pkImportStagingId = 27429 instead of the expected match.
--
-- use TabX
-- GO

if object_id('tempdb..#isai_row')       is not null drop table #isai_row;
if object_id('tempdb..#brand_scores')   is not null drop table #brand_scores;
if object_id('tempdb..#token_hits')     is not null drop table #token_hits;
if object_id('tempdb..#product_ranked') is not null drop table #product_ranked;
GO

declare @tis_id int = 27429;

-- ── Section 1: ISAI source row ───────────────────────────────────────────────

select top 1
   fkImportStagingId
  ,ItemAsListed
  ,Brand
  ,ProductName        as ai_ProductName
  ,BrandKeywords
  ,ProductKeywords
into #isai_row
from TabX.ImportStagingAI
where fkImportStagingId = @tis_id
order by pkImportStagingAIId desc;

select 'ISAI data' as section, * from #isai_row;

-- ── Section 2: brand resolution ─────────────────────────────────────────────

select
   b.pkBrandId
  ,b.BrandDescription
  ,count(distinct lower(trim(bkw.value collate SQL_Latin1_General_Cp1251_CS_AS))) as brand_kw_hits
  ,row_number() over (
      order by count(distinct lower(trim(bkw.value collate SQL_Latin1_General_Cp1251_CS_AS))) desc,
               len(b.BrandDescription) asc,
               b.pkBrandId asc
   ) as brand_rank
into #brand_scores
from #isai_row as isai
cross apply string_split(isai.BrandKeywords, '|') as bkw
join Common.Brands as b
   on b.IsActive = 1
  and len(trim(bkw.value)) > 2
  and lower(b.BrandDescription) like '%' + replace(replace(replace(replace(
         lower(trim(bkw.value collate SQL_Latin1_General_Cp1251_CS_AS)),
         '\','\\'), '%','\%'), '_','\_'), '[','\[') + '%' escape '\'
where isai.BrandKeywords is not null
group by b.pkBrandId, b.BrandDescription;

select 'Brand resolution' as section, * from #brand_scores order by brand_rank;

-- ── Section 3: per-token product hits (within resolved brand) ────────────────

select
   trim(pkw.value collate SQL_Latin1_General_Cp1251_CS_AS)  as token
  ,p.pkProductId
  ,p.ProductName
into #token_hits
from #isai_row as isai
join #brand_scores as bb on bb.brand_rank = 1
cross apply string_split(isai.ProductKeywords, '|') as pkw
join Common.Products as p
   on p.fkBrandId = bb.pkBrandId
  and p.IsActive = 1
  and len(trim(pkw.value)) > 2
  and lower(p.ProductName) like '%' + replace(replace(replace(replace(
         lower(trim(pkw.value collate SQL_Latin1_General_Cp1251_CS_AS)),
         '\','\\'), '%','\%'), '_','\_'), '[','\[') + '%' escape '\'
where isai.ProductKeywords is not null;

select 'Token hits' as section, token, pkProductId, ProductName
from #token_hits
order by ProductName, token;

-- ── Section 4: final product ranking ────────────────────────────────────────

select
   count(distinct lower(token))   as kw_hits
  ,len(ProductName)               as name_len     -- tiebreaker 2: shorter wins
  ,pkProductId                                    -- tiebreaker 3: lower PK wins
  ,ProductName
  ,row_number() over (
      order by count(distinct lower(token)) desc,
               len(ProductName) asc,
               pkProductId asc
   ) as final_rank
into #product_ranked
from #token_hits
group by pkProductId, ProductName;

select
   'Product ranking'   as section
  ,final_rank
  ,kw_hits
  ,name_len
  ,pkProductId
  ,ProductName
  ,case when final_rank = 1 then '<<< WINNER' else '' end as winner
from #product_ranked
order by final_rank;

-- ── Cleanup ──────────────────────────────────────────────────────────────────

drop table if exists #isai_row;
drop table if exists #brand_scores;
drop table if exists #token_hits;
drop table if exists #product_ranked;
GO
