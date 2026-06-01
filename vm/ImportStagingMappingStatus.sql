

select pkImportStagingId
      ,fkLocationId
      ,ExternalMenuId
      ,TabDetailDescription

      ,fkProductId
      ,cp.ProductName
	  
	  ,fkContainerId
	  ,cc.ContainerDescription

      ,tis.fkProductTypeId
	  ,cpt.TypeDescription

      ,tis.fkProductCategoryId
	  ,cpc.CategoryName

      ,fkNewProductBrandId
	  ,cb.BrandDescription

  from TabX.ImportStaging as tis
  left outer join Common.Products as cp on (tis.fkProductId = cp.pkProductId and cp.IsActive = 1)
  left outer join Common.Containers as cc on (tis.fkContainerId = cc.pkContainerId and cc.IsActive = 1)
  left outer join Common.ProductTypes as cpt on (tis.fkProductTypeId = cpt.pkProductTypeId and cpt.IsActive = 1)
  left outer join Common.ProductCategories as cpc on (tis.fkProductCategoryId = cpc.pkProductCategoryId and cpc.IsActive = 1)
  left outer join Common.Brands as cb on (tis.fkNewProductBrandId = cb.pkBrandId and cb.IsActive = 1)




  order by TabDetailDescription asc

