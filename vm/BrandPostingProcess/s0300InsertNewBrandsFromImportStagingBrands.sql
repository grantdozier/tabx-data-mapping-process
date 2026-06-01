--USE TabX
--GO


INSERT INTO Common.Brands
(BrandDescription
,IsActive
,fkCreatedByUserId
,DateCreated
,fkModifiedByUserId
,DateModified
,DefaultOriginCity
,fkDefaultOriginCountryId
,fkDefaultOriginStateProvinceId
,BrandDescriptionShort
,fkParentBrandId)

SELECT 
BrandDescription
,1 as IsActive
,1 as fkCreatedByUserId
,getdate() as DateCreated
,1 as fkModifiedByUserId
,getdate() as DateModified
,DefaultOriginCity
,fkDefaultOriginCountryId
,fkDefaultOriginStateProvinceId
,BrandDescriptionShort
,fkParentBrandId

from 
( select *
  from
  (  select
     Brand
     ,row_number() over (partition by BrandDescription order by fkDefaultOriginCountryId desc, fkDefaultOriginStateProvinceId asc, len(BrandDescriptionShort) desc) as rownum  
     ,BrandDescription
     ,DefaultOriginCity
     ,fkDefaultOriginCountryId
     ,fkDefaultOriginStateProvinceId
     ,BrandDescriptionShort
     ,fkParentBrandId
     ,fkBrandIdExisting
  --,IsInsertBrandAlias
  --,IsNewBrand
     from tabx.ImportStagingBrands as isb
     where IsNewBrand = 1
     -- 20260527 wpa - removed to give editor full control - some entires not being loaded
	 --and fkBrandIdExisting is null
  --   and ( BrandDescription like 'high%' or BrandDescription like 'lazz%') 
  
  ) sisb
) srn 
where rownum = 1
--   order by brand asc


 






      --,fkBrandIdExisting
      --,DefaultOriginCountry
      --,IsInsertCountryAlias
      --,DefaultOriginStateProvince
      --,IsNewStateProvince
      --,IsInsertStateProvinceAlias
      --,fkCreatedByUserId
      --,DateCreated
      --,fkModifiedByUserId
      --,DateModified
      --,RowVersionStamp
--  FROM TabX.ImportStagingBrands

GO

