--USE TabX-Reporting
--GO

with ctetd as (



  SELECT 
     row_number() over (order by td.pkTabDetailId asc) as rownum
     ,td.pkTabDetailId
     ,td.fkTabId
     ,td.Qty
     ,td.Description
     ,td.Amount
     --,td.SortOrder
     --,td.IsActive
     --,td.fkCreatedByUserId
     --,td.DateCreated
     --,td.fkModifiedByUserId
     --,td.DateModified
      
	 ,td.ExternalId
     ,td.ExternalMenuId
     ,td.ItemDate
     --,td.Tax
     --,td.fkParentDetailId
     --,td.TaxIncluded
  FROM TabX.TabDetails as td 
  inner join tabx.tabs as t on (td.fkTabId = t.pkTabId and t.IsActive=1)
  inner join tabx.LocationPosIdentifiers as lpi on (t.fkLocationPosIdentifierId=lpi.pkLocationPosIdentifierId and lpi.IsActive=1)
  where td.IsActive=1
  and lpi.fkLocationId = 103

  )
  select top 1000
     td.rownum
	 ,td.pkTabDetailId
     ,td.fkTabId
     ,td.Qty
     ,td.Description
     ,td.Amount
     --,td.SortOrder
     --,td.IsActive
     --,td.fkCreatedByUserId
     --,td.DateCreated
     --,td.fkModifiedByUserId
     --,td.DateModified
      
	 ,td.ExternalId
     ,td.ExternalMenuId
     ,td.ItemDate
     --,td.Tax
     --,td.fkParentDetailId
     --,td.TaxIncluded
	 ,tdmod.rownum as tdmodrownum
	 ,tdmod.Description as ModDesc
	 ,tdmod.ExternalMenuId
	 from ctetd as td
     left outer join ctetd tdmod on (td.rownum+1=tdmod.rownum and tdmod.Description like '%oz%')


  and tdmod.pkTabDetailId is not null
  and (tdmod.Description like '[1-3] oz' or tdmod.Description like '[1-3]oz')


  order by td.pkTabDetailId asc
--  order by td.Description asc


GO


