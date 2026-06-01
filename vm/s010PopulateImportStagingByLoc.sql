--USE [TabX]
--GO


-- when     who what
-- 20250628 wpa Added exclusion for previously mapped items


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
   --, count(*) as cnt
from 
   TabX.TabDetails as td
   INNER JOIN TabX.Tabs as t on (td.fkTabId = t.pkTabId)
   INNER JOIN TabX.LocationPosIdentifiers as lpi on (t.fkLocationPosIdentifierId = lpi.pkLocationPosIdentifierId)
   INNER JOIN TabX.Locations as l on (lpi.fkLocationId=l.pkLocationId)
   left outer join TabX.LocationInventory as li on (li.fkLocationId=l.pkLocationID and li.ExternalMenuId=td.ExternalMenuId)
where td.DateCreated > '2022-09-30'
and qty > 0
and (li.pkLocationInventoryId is NULL  or (li.pkLocationInventoryId is not NULL and li.IsActive<>1))   --omit already mapped data
and td.ExternalMenuId is not null
--and coalesce(try_cast(Amount as decimal(12,2)),0) > 0
----------------------
and pkLocationId in (103)                      --(127, 140)
----------------------
group by td.Description, l.pkLocationId, td.ExternalMenuId
--order by td.description desc

