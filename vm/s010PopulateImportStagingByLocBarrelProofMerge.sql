--USE TabX-Reporting
--GO
 
-- currently only used for Barrel Proof
-- Merges second line pour modifiers (1oz, 2oz, 1 oz, 2 oz)



with ctetd as (
  SELECT 
  row_number() over (order by td.pkTabDetailId asc) as rownum
  ,lpi.fkLocationId
  ,td.pkTabDetailId
  ,td.fkTabId
  ,td.Qty
  ,td.Description
  ,td.Amount
  --,td.SortOrder
  --,td.IsActive
  --,td.fkCreatedByUserId
  ,td.DateCreated
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
  and td.DateCreated > '2022-09-30'
  ----------------------
  and fkLocationId in (103)                      --(127, 140)
  ----------------------
  )


  INSERT INTO [TabX].[ImportStaging]
           ([fkLocationId]
           ,[ExternalMenuId]
           ,[TabDetailDescription]
		   ,QtyOrdered
           --,[fkBrandId]
           --,[fkProductId]
           --,[fkContainerId]
           --,[fkProductTypeId]
           --,[fkProductCategoryId]
           --,[ABV]
           --,[fkOriginCountryId]
           --,[fkOriginStateProvinceId]
           --,[OriginCity]
           --,[Keyword]
           --,[Weighting]
           ,[fkCreatedByUserId]
           ,[DateCreated]
           ,[fkModifiedByUserId]
           ,[DateModified]
		   ,LastSold
		   ,MinPrice
		   ,MaxPrice
		   )





  -- Main selection query
  select top 250
  l.pkLocationId as fkLocationID
  ,td.ExternalMenuId
  ,td.Description
  ,sum(case when qty=0 then 1 else qty end) as QtyOrdered
  ,1 as fkCreatedByUserId
  ,getdate() as DateCreated
  ,1 as fkModifiedByUserId
  ,getdate() as DateModified
  ,min(datediff(day, td.datecreated, getdate())) as LastSold
  ,min(case when coalesce(qty,0)<1 then try_cast(Amount as decimal(12,2)) else cast(coalesce(try_cast(Amount as decimal(12,2)),0) / qty as decimal(12,2)) end ) as MinPrice
  ,max(case when coalesce(qty,0)<1 then try_cast(Amount as decimal(12,2)) else cast(coalesce(try_cast(Amount as decimal(12,2)),0) / qty as decimal(12,2)) end ) as MaxPrice
  --,min(cast(coalesce(try_cast(Amount as decimal(12,2)), 0) as decimal(12,2))) as MinPrice
  --,max(cast(coalesce(try_cast(Amount as decimal(12,2)), 0) as decimal(12,2))) as OldMaxPrice
  --,count(*) as cnt
  from 
  (
    -- logic to glue together lines 
    select 
    td.rownum
    ,td.fkLocationId
	,td.pkTabDetailId
    ,td.fkTabId
    ,td.Qty
    ,trim(td.Description)+ coalesce(' '+trim(tdmod.Description), '') as Description
	--,trim(td.Description)+case when tdmod.Description is not null and left(trim(tdmod.Description),1) > '1' then ' '+trim(tdmod.Description) else '' end as Description
    ,td.Amount
    --,td.SortOrder
    --,td.IsActive
    --,td.fkCreatedByUserId
    ,td.DateCreated
    --,td.fkModifiedByUserId
    --,td.DateModified
    --,td.ExternalId
    ,coalesce(tdmod.ExternalMenuId,td.ExternalMenuId) as ExternalMenuId
    ,td.ItemDate
    --,td.Tax
    --,td.fkParentDetailId
    --,td.TaxIncluded
    ,tdmod.rownum as tdmodrownum
    ,tdmod.Description as ModDesc
    --,tdmod.ExternalMenuId 
    from ctetd as td
    left outer join ctetd tdmod on (td.rownum+1=tdmod.rownum and (trim(tdmod.Description) like '[1-3] oz' or trim(tdmod.Description) like '[1-3]oz'))
    where trim(td.Description) not like '[123] oz' 
    and trim(td.Description) not like '[123]oz'
    --and tdmod.pkTabDetailId is not null
  ) as td
  --INNER JOIN TabX.Tabs as t on (td.fkTabId = t.pkTabId)
  --INNER JOIN TabX.LocationPosIdentifiers as lpi on (t.fkLocationPosIdentifierId = lpi.pkLocationPosIdentifierId)
  INNER JOIN TabX.Locations as l on (td.fkLocationId=l.pkLocationId)
  left outer join TabX.LocationInventory as li on (li.fkLocationId=l.pkLocationID and li.ExternalMenuId=td.ExternalMenuId)
  where qty > 0
  and (li.pkLocationInventoryId is NULL  or (li.pkLocationInventoryId is not NULL and li.IsActive<>1)) --omit already mapped data
  and td.ExternalMenuId is not null
  --and coalesce(try_cast(Amount as decimal(12,2)),0) > 0
  group by td.Description, l.pkLocationId, td.ExternalMenuId


go





