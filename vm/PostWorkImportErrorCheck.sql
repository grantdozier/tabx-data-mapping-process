

with ctetis  as (


SELECT pkImportStagingId
      ,fkLocationId
      ,ExternalMenuId
      ,TabDetailDescription
      ,fkProductId
      ,fkContainerId
      --,fkCreatedByUserId
      --,DateCreated
      --,fkModifiedByUserId
      --,DateModified
      --,RowVersionStamp
      ,QtyOrdered
      ,fkInventoryId
      ,fkLocationInventoryId
      ,LastSold
      ,MinPrice
      ,MaxPrice
      ,NewProductName
      ,IsNewProduct
      ,IsNewProductAlias
      ,tis.fkProductTypeId
      ,tis.fkProductCategoryId
      ,fkNewProductBrandId
      ,NewProductBrand
      ,cb.BrandDescription
      ,cp.ProductName
	  ,cc.ContainerDescription
	  ,cpt.TypeDescription
	  ,cpt.fkContainer_Default
      ,cptdc.ContainerDescription as DefaultContainerDescription
  FROM TabX.ImportStaging as tis
  left outer join Common.Products as cp on (cp.pkProductId=tis.fkProductId and cp.IsActive=1)
  left outer join Common.Containers as cc on (cc.pkContainerId=tis.fkContainerId and cc.IsActive=1)
  left outer join Common.Brands as cb on (cb.pkBrandId=tis.fkNewProductBrandId and cb.IsActive=1)
  left outer join Common.ProductTypes as cpt on (cpt.pkProductTypeId=tis.fkProductTypeId and cpt.IsActive=1)
  left outer join Common.Containers as cptdc on (cptdc.pkContainerId=cpt.fkContainer_Default and cptdc.IsActive=1)




)

select * from (

  select 1 as warnlvl, pkImportStagingId, TabDetailDescription, 'New product without usable name ('+coalesce(NewProductName,'null')+')' as msg from ctetis where IsNewProduct=1 and (NewProductName is null or NewProductName < '!') 
  union all
  select 1 as warnlvl, pkImportStagingId, TabDetailDescription, 'Unassigned item ('+coalesce(NewProductName,'null')+')' as msg from ctetis where coalesce(IsNewProduct,0)=0 and fkProductId is null
  union all
  
  select 2 as warnlvl, pkImportStagingId, TabDetailDescription, 'Liquor not set to shot ('+coalesce(ContainerDescription, 'null')+': '+coalesce(ProductName,'null')+')' as msg from ctetis where fkProductTypeId=2 and fkContainerId not in (26, 30, 36, 41, 55, 56, 65, 77)
  union all
  select 2 as warnlvl, pkImportStagingId, TabDetailDescription, coalesce(TypeDescription, 'null')+' not set to '+coalesce(DefaultContainerDescription, 'null')+' ('+coalesce(ContainerDescription, 'null')+': '+coalesce(ProductName,'null')+')' as msg from ctetis where fkContainer_Default <> fkContainerId 
  union all
  
  
  
  
  select 4 as warnlvl, pkImportStagingId, TabDetailDescription, 'New product without usable brand description ('+coalesce(BrandDescription,'null')+')' as msg from ctetis where IsNewProduct=1 and (BrandDescription is null or BrandDescription < '!') 
  union all
  select 5 as warnlvl, pkImportStagingId, TabDetailDescription, 'Low dollar value item not assigned as ZZ Undefined (Max $'+cast(MaxPrice as varchar(20))+': '+coalesce(ProductName,'null')+')' as msg from ctetis where coalesce(IsNewProduct,0)=0 and MaxPrice<=0.01 and fkProductId <> 1
  
) s
where warnlvl <= 2
--order by warnlvl asc, msg asc
--order by TabDetailDescription asc
order by pkImportStagingId asc




;

