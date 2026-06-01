-- Check that all ImportStaging items are mapped into LocationInventory
-- it should return 0 rows



SELECT TOP (1000) [pkImportStagingId]
      ,[fkLocationId]
      ,[ExternalMenuId]
      ,[TabDetailDescription]
      ,[fkProductId]
      ,[fkContainerId]
      ,[fkCreatedByUserId]
      ,[DateCreated]
      ,[fkModifiedByUserId]
      ,[DateModified]
      ,[RowVersionStamp]
      ,[QtyOrdered]
      ,[fkInventoryId]
      ,[fkLocationInventoryId]
      ,[LastSold]
      ,[MinPrice]
      ,[MaxPrice]
      ,[NewProductName]
      ,[IsNewProduct]
      ,[IsNewProductAlias]
      ,[fkProductTypeId]
      ,[fkProductCategoryId]
      ,[fkNewProductBrandId]
      ,[NewProductBrand]
  FROM [TabX].[ImportStaging]
  where fkLocationInventoryId is null

