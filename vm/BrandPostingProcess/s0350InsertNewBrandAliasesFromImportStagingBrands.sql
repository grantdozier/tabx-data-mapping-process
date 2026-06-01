--USE TabX
--GO

INSERT INTO Common.BrandAliases
           (fkBrandId
           ,BrandAlias
           ,IsActive
           ,fkCreatedByUserId
           ,DateCreated
           ,fkModifiedByUserId
           ,DateModified)

-- Aliases for existing brands
SELECT
fkBrandIdExisting as fkBrandId
,Brand as BrandAlias
,1 as IsActive
,1 as fkCreatedByUserId
,getdate() as DateCreated
,1 as fkModifiedByUserId
,getdate() as DateModified

from
(  select
   Brand
   ,BrandDescription
   ,DefaultOriginCity
   ,fkDefaultOriginCountryId
   ,fkDefaultOriginStateProvinceId
   ,BrandDescriptionShort
   ,fkParentBrandId
   ,fkBrandIdExisting
   from tabx.ImportStagingBrands as isb
   where IsInsertBrandAlias = 1
   and fkBrandIdExisting is not null
   -- skip aliases that already exist in Common.BrandAliases
   and not exists (
      select 1 from Common.BrandAliases ba
      where ba.BrandAlias = isb.Brand collate SQL_Latin1_General_Cp1251_CS_AS
   )
) sisb

union all

-- Aliases for newly created brands

SELECT
fkBrandIdExisting as fkBrandId
,Brand as BrandAlias
,1 as IsActive
,1 as fkCreatedByUserId
,getdate() as DateCreated
,1 as fkModifiedByUserId
,getdate() as DateModified

from
(  select
   isb.Brand
   ,isb.BrandDescription
   ,isb.DefaultOriginCity
   ,isb.fkDefaultOriginCountryId
   ,isb.fkDefaultOriginStateProvinceId
   ,isb.BrandDescriptionShort
   ,isb.fkParentBrandId
   ,cb.pkBrandId as fkBrandIdExisting
   from tabx.ImportStagingBrands as isb
   -- INNER JOIN ensures rows with no matching brand are skipped rather than inserting NULL fkBrandId
   inner join common.Brands as cb on (isb.BrandDescription = cb.BrandDescription and cb.IsActive = 1)
   -- Removed 20260520 wpa to imporve consistency
   --inner join common.Brands as cb on ((isb.BrandDescription = cb.BrandDescription or isb.BrandDescription = cb.BrandDescriptionShort) and cb.IsActive = 1)
   where IsInsertBrandAlias = 1
   and fkBrandIdExisting is null
   -- skip aliases that already exist in Common.BrandAliases
   and not exists (
      select 1 from Common.BrandAliases ba
      where ba.BrandAlias = isb.Brand collate SQL_Latin1_General_Cp1251_CS_AS
   )
) sisb

GO
