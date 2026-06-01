--USE TabX-Reporting
--GO



SELECT td.pkTabDetailId
      ,td.fkTabId
      ,td.Qty
      ,td.Description
      ,td.Amount
      ,td.SortOrder
      ,td.IsActive
      ,td.fkCreatedByUserId
      ,td.DateCreated
      ,td.fkModifiedByUserId
      ,td.DateModified
      ,td.ExternalId
      ,td.ExternalMenuId
      ,td.ItemDate
      ,td.Tax
      ,td.fkParentDetailId
      ,td.TaxIncluded
  FROM TabX.TabDetails as td 
  inner join tabx.tabs as t on (td.fkTabId = t.pkTabId and t.IsActive=1)
  inner join tabx.LocationPosIdentifiers as lpi on (t.fkLocationPosIdentifierId=lpi.pkLocationPosIdentifierId and lpi.IsActive=1)
  where td.IsActive=1
  and lpi.fkLocationId = 103

  order by td.pkTabDetailId asc
  

GO


