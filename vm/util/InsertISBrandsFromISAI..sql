--USE TabX-Reporting
--GO

/*

INSERT INTO [TabX].[ImportStagingBrands]
           ([TabDetailDescription]
           ,[Brand]
           ,[fkBrandIdExisting]
           ,[IsInsertBrandAlias]
           ,[IsNewBrand]
           ,[BrandDescription]
           ,[BrandDescriptionShort]
           ,[fkParentBrandId]
           ,[DefaultOriginCity]
           ,[DefaultOriginCountry]
           ,[fkDefaultOriginCountryId]
           ,[IsInsertCountryAlias]
           ,[DefaultOriginStateProvince]
           ,[fkDefaultOriginStateProvinceId]
           ,[IsNewStateProvince]
           ,[IsInsertStateProvinceAlias]
           ,[fkCreatedByUserId]
           ,[DateCreated]
           ,[fkModifiedByUserId]
           ,[DateModified])

*/

select
TabDetailDescription
,Brand
,fkBrandIdExisting
,IsInsertBrandAlias
,IsNewBrand
,Brand as BrandDescription
,left(Brand, 50) as BrandDescriptionShort
,fkExistingBrandParentId as fkParentBrandId

,City as DefaultOriginCity

,Country as DefaultOriginCountry
,resolved_country_id as fkDefaultOriginCountryId
,case when resolved_country_id is null and Country is not null then 1 else 0 end as IsInsertCountryAlias
,StateProv as DefaultOriginStateProvince
,resolved_stateprov_id as fkDefaultOriginStateProvinceId
,case when resolved_stateprov_id is null and StateProv is not null and resolved_country_id is not null then 1 else 0 end as IsNewStateProvince
,0 as IsInsertStateProvinceAlias

,1 as fkCreatedByUserId
,getdate() as DateCreated
,1 as fkModifiedByUserId
,getdate() as DateModified

from
(
    select
    TabDetailDescription, Brand
    -- Priority: exact → kw_brand (scored) → token_brand (overlap) → fuzzy substring → soundex
    ,coalesce(fkExactBrandId, kw_brand.pkBrandId, token_brand.pkBrandId, fkFuzzyBrandId, soundex_brand.pkBrandId) as fkBrandIdExisting
    ,coalesce(fkExactParentBrandId, kw_brand.fkParentBrandId, token_brand.fkParentBrandId, fkFuzzyParentBrandId, soundex_brand.fkParentBrandId) as fkExistingBrandParentId
    ,City, StateProv, Country
    ,coalesce(cc_code.pkCountryId, cc.pkCountryId, cca.fkCountryId) as resolved_country_id
    ,coalesce(csp.pkStateProvinceId, cspa.fkStateProvinceId) as resolved_stateprov_id
    -- IsInsertBrandAlias: fires when string-based matching (exact or fuzzy) found a brand but no exact match.
    -- kw_brand/token_brand/soundex-only matches are suppressed (IsNewBrand=0 + IsInsertBrandAlias=0).
    ,case when coalesce(fkExactBrandId, fkFuzzyBrandId) is not null and has_exact_brand = 0 and cba.BrandAlias is null then 1 else 0 end as IsInsertBrandAlias
    ,case when coalesce(fkExactBrandId, kw_brand.pkBrandId, token_brand.pkBrandId, fkFuzzyBrandId, soundex_brand.pkBrandId) is null then 1 else 0 end as IsNewBrand
    from
    (
        SELECT
        max(ItemAsListed) as TabDetailDescription
        ,isai.Brand
        ,max(isai.brand_norm) as brand_norm
        ,coalesce(min(cb.pkBrandId),         min(cbs.pkBrandId),         min(cb_s.pkBrandId))   as fkExactBrandId
        ,coalesce(min(sinb.pkBrandId),       min(bins.pkBrandId),        min(bins_s.pkBrandId)) as fkFuzzyBrandId
        ,coalesce(min(cb.fkParentBrandId),   min(cbs.fkParentBrandId),   min(cb_s.fkParentBrandId))   as fkExactParentBrandId
        ,coalesce(min(sinb.fkParentBrandId), min(bins.fkParentBrandId),  min(bins_s.fkParentBrandId)) as fkFuzzyParentBrandId
        ,case when min(cb.pkBrandId) is not null or min(cbs.pkBrandId) is not null or min(cb_s.pkBrandId) is not null then 1 else 0 end as has_exact_brand
        ,max(City) as City
        ,max(StateProv) as StateProv
        ,max(Country) as Country
        ,max(isai.country_norm) as country_norm
        ,max(isai.country_code) as country_code
        ,max(isai.brand_keywords) as brand_keywords
        ,max(isai.stateprov_norm) as stateprov_norm
        FROM
        (
            select
            max(brand) as brand
            ,lower(trim(max(brand) collate SQL_Latin1_General_Cp1251_CS_AS)) as brand_norm
            ,replace(replace(replace(replace(lower(trim(max(brand) collate SQL_Latin1_General_Cp1251_CS_AS)),' ',''),'''',''),'-',''),'.','') as brand_norm_s
            ,max(ItemAsListed) as ItemAsListed
            ,max(City) as City
            ,max(StateProv) as StateProv
            ,max(Country) as Country
            ,max(lower(trim(Country collate SQL_Latin1_General_Cp1251_CS_AS))) as country_norm
            ,max(upper(trim(CountryCode collate SQL_Latin1_General_Cp1251_CS_AS))) as country_code
            ,max(BrandKeywords) as brand_keywords
            ,max(lower(trim(StateProv collate SQL_Latin1_General_Cp1251_CS_AS))) as stateprov_norm
            from TabX.ImportStagingAI
            where brand is not null
            group by lower(trim(brand collate SQL_Latin1_General_Cp1251_CS_AS))
        ) as isai
        left outer join common.Brands as cb   on (lower(trim(cb.BrandDescription collate SQL_Latin1_General_Cp1251_CS_AS)) = isai.brand_norm and cb.IsActive = 1)
        left outer join common.Brands as cbs  on (lower(trim(cbs.BrandDescriptionShort collate SQL_Latin1_General_Cp1251_CS_AS)) = isai.brand_norm and cbs.IsActive = 1)
        left outer join common.Brands as sinb on (lower(trim(sinb.BrandDescription collate SQL_Latin1_General_Cp1251_CS_AS)) like '%' + replace(replace(replace(replace(isai.brand_norm,'\','\\'),'%','\%'),'_','\_'),'[','\[') + '%' escape '\' and sinb.IsActive = 1)
        left outer join common.Brands as bins   on (isai.brand_norm like '%' + replace(replace(replace(replace(lower(trim(bins.BrandDescription collate SQL_Latin1_General_Cp1251_CS_AS)),'\','\\'),'%','\%'),'_','\_'),'[','\[') + '%' escape '\' and bins.IsActive = 1)
        left outer join common.Brands as cb_s   on (replace(replace(replace(replace(lower(trim(cb_s.BrandDescription collate SQL_Latin1_General_Cp1251_CS_AS)),' ',''),'''',''),'-',''),'.','') = isai.brand_norm_s and cb_s.IsActive = 1)
        left outer join common.Brands as bins_s on (isai.brand_norm_s like '%' + replace(replace(replace(replace(replace(replace(replace(replace(lower(trim(bins_s.BrandDescriptionShort collate SQL_Latin1_General_Cp1251_CS_AS)),'\','\\'),'%','\%'),'_','\_'),'[','\['),' ',''),'''',''),'-',''),'.','') + '%' escape '\' and len(bins_s.BrandDescriptionShort) >= 5 and bins_s.IsActive = 1)
        group by Brand
    ) agg
    outer apply (
        select top 1 cba.BrandAlias
        from Common.BrandAliases as cba
        where lower(trim(cba.BrandAlias collate SQL_Latin1_General_Cp1251_CS_AS)) = agg.brand_norm
          and cba.IsActive = 1
        order by cba.pkBrandAliasId asc
    ) as cba
    outer apply (
        select top 1 b.pkBrandId, b.fkParentBrandId
        from string_split(agg.brand_keywords, '|') as kw
        join Common.Brands as b
           on b.IsActive = 1
          and len(trim(kw.value)) > 2
          and lower(b.BrandDescription) like '%' + replace(replace(replace(replace(
                 lower(trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS)),
                 '\','\\'),'%','\%'),'_','\_'),'[','\[') + '%' escape '\'
        where agg.brand_keywords is not null
          and agg.brand_keywords <> ''
        group by b.pkBrandId, b.fkParentBrandId, b.BrandDescription
        having count(distinct lower(trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS))) * 2 >=
               (select count(distinct lower(trim(v.value)))
                from string_split(agg.brand_keywords, '|') as v
                where len(trim(v.value)) > 2)
        order by count(distinct lower(trim(kw.value collate SQL_Latin1_General_Cp1251_CS_AS))) desc,
                 len(b.BrandDescription) asc, b.pkBrandId asc
    ) as kw_brand
    outer apply (
        select top 1 b.pkBrandId, b.fkParentBrandId
        from Common.Brands as b
        where b.IsActive = 1
          and (select count(*)
               from string_split(agg.brand_norm, ' ') as t
               where len(t.value) > 2
                 and ' ' + lower(b.BrandDescription) + ' ' like '% ' + t.value + ' %'
              ) * 2 >=
              (select count(*)
               from string_split(agg.brand_norm, ' ') as t
               where len(t.value) > 2)
          and (select count(*)
               from string_split(agg.brand_norm, ' ') as t
               where len(t.value) > 2) > 0
        order by
           (select count(*)
            from string_split(agg.brand_norm, ' ') as t
            where len(t.value) > 2
              and ' ' + lower(b.BrandDescription) + ' ' like '% ' + t.value + ' %'
           ) desc,
           len(b.BrandDescription) asc, b.pkBrandId asc
    ) as token_brand
    outer apply (
        select top 1 b.pkBrandId, b.fkParentBrandId
        from Common.Brands as b
        where b.IsActive = 1
          and len(agg.brand_norm) > 4
          and DIFFERENCE(agg.brand_norm, lower(b.BrandDescription)) = 4
        order by len(b.BrandDescription) asc, b.pkBrandId asc
    ) as soundex_brand
    outer apply (select top 1 pkCountryId from Common.Countries where upper(trim(CountryCode)) = agg.country_code) as cc_code
    outer apply (
        select top 1 cc.pkCountryId
        from Common.Countries as cc
        where cc_code.pkCountryId is null
          and (   agg.country_norm = lower(trim(cc.CountryName collate SQL_Latin1_General_Cp1251_CS_AS))
               or agg.country_norm = lower(trim(cc.CountryCode collate SQL_Latin1_General_Cp1251_CS_AS))
               or agg.country_norm = lower(trim(cc.CountryCommonName collate SQL_Latin1_General_Cp1251_CS_AS)))
        order by cc.pkCountryId asc
    ) as cc
    outer apply (
        select top 1 cca.fkCountryId
        from Common.CountryAliases as cca
        where cc_code.pkCountryId is null
          and cc.pkCountryId is null
          and cca.IsActive = 1
          and agg.country_norm = lower(trim(cca.CountryAlias collate SQL_Latin1_General_Cp1251_CS_AS))
        order by cca.pkCountryAliasId asc
    ) as cca
    outer apply (
        select top 1 pkStateProvinceId
        from Common.StateProvinces
        where agg.stateprov_norm = lower(trim(StateProvinceName collate SQL_Latin1_General_Cp1251_CS_AS))
           or agg.stateprov_norm = lower(trim(Abbrev collate SQL_Latin1_General_Cp1251_CS_AS))
        order by pkStateProvinceId asc
    ) as csp
    outer apply (
        select top 1 fkStateProvinceId
        from Common.StateProvinceAliases
        where agg.stateprov_norm = lower(trim(StateProvinceAlias collate SQL_Latin1_General_Cp1251_CS_AS))
        order by pkStateProvinceAliasId asc
    ) as cspa
) mid
where IsNewBrand = 1          -- new brand
   or IsInsertBrandAlias = 1  -- known brand, string not yet in Brands or BrandAliases


GO


