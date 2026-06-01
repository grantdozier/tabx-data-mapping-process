

--select
UPDATE tis
   SET 
   --fkNewProductBrandId = 
   --case 
   --  when fkProductTypeId = 4 and IsNewProduct and  then 000           -- MD -> Location Name  
   --end
   fkContainerId = 
   case 
     when fkProductTypeId in (6, 11) then 32                                           -- Food & Mech -> each
     when fkProductTypeId = 5  then 29                                                 -- Undefined -> Undefined
	 when (fkContainerId is null or fkContainerId = 29) then cpt.fkContainer_Default   -- To default if unassigned    
     else fkContainerId                                                                -- Orig 
   end	 


from TabX.ImportStaging as tis
left outer join Common.ProductTypes as cpt on (cpt.pkProductTypeId=tis.fkProductTypeId and cpt.IsActive=1)




/*
   
   [fkLocationId] = <fkLocationId, int,>
      ,[ExternalMenuId] = <ExternalMenuId, varchar(500),>
      ,[TabDetailDescription] = <TabDetailDescription, varchar(2000),>
      ,[fkProductId] = <fkProductId, int,>
      ,[fkContainerId] = <fkContainerId, int,>
      ,[fkCreatedByUserId] = <fkCreatedByUserId, int,>
      ,[DateCreated] = <DateCreated, datetime,>
      ,[fkModifiedByUserId] = <fkModifiedByUserId, int,>
      ,[DateModified] = <DateModified, datetime,>
      ,[QtyOrdered] = <QtyOrdered, int,>
      ,[fkInventoryId] = <fkInventoryId, int,>
      ,[fkLocationInventoryId] = <fkLocationInventoryId, int,>
      ,[LastSold] = <LastSold, int,>
      ,[MinPrice] = <MinPrice, decimal(12,2),>
      ,[MaxPrice] = <MaxPrice, decimal(12,2),>
      ,[NewProductName] = <NewProductName, varchar(500),>
      ,[IsNewProduct] = <IsNewProduct, bit,>
      ,[IsNewProductAlias] = <IsNewProductAlias, bit,>
      ,[fkProductTypeId] = <fkProductTypeId, int,>
      ,[fkProductCategoryId] = <fkProductCategoryId, int,>
      ,[fkNewProductBrandId] = <fkNewProductBrandId, int,>
      ,[NewProductBrand] = <NewProductBrand, varchar(255),>
 */
 
 GO


