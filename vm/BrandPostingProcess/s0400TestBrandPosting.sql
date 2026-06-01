--use tabx
--go

-- Show inserted aliases - all should have an entry in the last column

SELECT TabDetailDescription
      ,Brand
      ,fkBrandIdExisting
      ,IsInsertBrandAlias          --
      ,IsNewBrand                  --
      ,BrandDescription
      ,BrandDescriptionShort
	  ,cba.BrandAlias as NewBrandAlias
      --,fkParentBrandId
      --,DefaultOriginCity
      --,DefaultOriginCountry
      --,fkDefaultOriginCountryId
      --,IsInsertCountryAlias          --
      --,DefaultOriginStateProvince
      --,fkDefaultOriginStateProvinceId
      --,IsNewStateProvince
      --,IsInsertStateProvinceAlias
	  
  FROM TabX.ImportStagingBrands as isb
  left outer join Common.BrandAliases as cba on (cba.fkBrandId=isb.fkBrandIdExisting)
  where IsInsertBrandAlias = 1
  
  order by TabDetailDescription asc

-- All belore should return 0 rows
  

select tisb.BrandDescription, cb.BrandDescription 
from TabX.ImportStagingBrands as tisb
left outer join Common.Brands as cb on ((tisb.BrandDescription = cb.BrandDescription or tisb.BrandDescription = cb.BrandDescriptionShort) and cb.IsActive=1)
where IsNewBrand = 1
and cb.pkBrandId is null

  
select tisb.BrandDescription, tisb.Brand, cba.BrandAlias, cb.BrandDescription
from TabX.ImportStagingBrands as tisb
left outer join Common.BrandAliases as cba on (tisb.Brand = cba.BrandAlias and cba.IsActive=1)
left outer join Common.Brands as cb on ((tisb.BrandDescription = cb.BrandDescription or tisb.BrandDescription = cb.BrandDescriptionShort) and cb.IsActive=1)
where IsInsertBrandAlias = 1
and cba.fkBrandId is null


-- Below not completed yet

/*
select tisb.* 
from TabX.ImportStagingBrands as tisb
where  tisb.IsInsertCountryAlias = 1
or  tisb.IsInsertStateProvinceAlias = 1

*/