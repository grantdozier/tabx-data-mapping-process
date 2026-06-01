
-- Purpose: Archive ImportStagingBrands to the ImportStagingBrandsArchive table
-- should return number of rows in ImportStaging








INSERT INTO [TabX].[ImportStagingBrandsArchive]
           ([pkImportStagingBrandsId]
           ,[TabDetailDescription]
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
SELECT [pkImportStagingBrandsId]
      ,[TabDetailDescription]
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
      ,[DateModified]
  FROM [TabX].[ImportStagingBrands]

GO



