-- Find new product items in ImportStaging that do not have a brand assigned



SELECT TOP (1000) [pkImportStagingId]
      ,[fkLocationId]
      --,[ExternalMenuId]
      ,[TabDetailDescription]
      --,[fkProductId]
      --,[fkContainerId]
      --,[fkCreatedByUserId]
      --,[DateCreated]
      --,[fkModifiedByUserId]
      --,[DateModified]
      --,[RowVersionStamp]
      --,[QtyOrdered]
      --,[fkInventoryId]
      --,[fkLocationInventoryId]
      --,[LastSold]
      --,[MinPrice]
      --,[MaxPrice]
      --,[NewProductName]
      --,[IsNewProduct]
      --,[IsNewProductAlias]
      --,[fkProductTypeId]
      --,[fkProductCategoryId]
      --,[fkNewProductBrandId]
      ,[NewProductBrand]
  FROM [TabX].[ImportStaging]
  where
  IsNewProduct        = 1
--   ImportStaging.NewProductName     IS NOT NULL
--   ImportStaging.fkProductTypeId    IS NOT NULL, <> 4, <> @NonAlcoholicTypeId
--   ImportStaging.fkProductCategoryId IS NOT NULL
--   Product name source: ImportStaging.NewProductName
  and fkNewProductBrandId is null
  and fkProductTypeId < 4

--
