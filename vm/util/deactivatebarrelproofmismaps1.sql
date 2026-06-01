USE [TabX-Reporting]
GO



  --select * from
  
  update tabx.LocationInventory 
  set IsActive=0
  where (trim(TabDetailDescription) like '[1-3] oz' or trim(TabDetailDescription) like '[1-3]oz')
  and fkLocationId = 103


GO


