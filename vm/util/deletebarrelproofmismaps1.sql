SELECT tisai.pkImportStagingAIId
      ,tis.TabDetailDescription
      ,tisai.ItemAsListed
      ,tisai.Brand
      ,tisai.ProductName
      ,tisai.ContainerSizeQty
      ,tisai.ContainerSizeUnit
      ,tisai.ContainerType
      ,tisai.ABV
      ,tisai.ProductType
      ,tisai.ProductCategory
      ,tisai.Country
      ,tisai.City
      ,tisai.StateProv
      ,tisai.fkImportStagingId
      ,tisai.BrandNameShort
      ,tisai.ProductKeywords
      ,tisai.IsWellKnownMixedDrink
      ,tisai.BrandKeywords
      ,tisai.CountryCode
  FROM TabX.ImportStagingAI as tisai
  inner join tabx.ImportStaging as tis on (tisai.fkImportStagingId=tis.pkImportStagingId)
  where (left(trim(tis.TabDetailDescription),4) like '[1-3] oz' or left(trim(tis.TabDetailDescription),3) like '[1-3]oz')
  and (left(trim(tisai.ItemAsListed),4) like '[1-3] oz' or left(trim(tisai.ItemAsListed),3) like '[1-3]oz')



  select * from tabx.ImportStaging as tis where (left(trim(tis.TabDetailDescription),4) like '[1-3] oz' or left(trim(tis.TabDetailDescription),3) like '[1-3]oz')

  select * from tabx.ImportStagingAI as tisai where (left(trim(tisai.ItemAsListed),4) like '[1-3] oz' or left(trim(tisai.ItemAsListed),3) like '[1-3]oz')



  delete from tabx.ImportStaging where (left(trim(TabDetailDescription),4) like '[1-3] oz' or left(trim(TabDetailDescription),3) like '[1-3]oz')

  delete from tabx.ImportStagingAI where (left(trim(ItemAsListed),4) like '[1-3] oz' or left(trim(ItemAsListed),3) like '[1-3]oz')







