--USE TabX
--GO


INSERT INTO Common.StateProvinces
           (Abbrev
           ,StateProvinceName
           ,IsActive
           ,fkCreatedByUserId
           ,DateCreated
           ,fkModifiedByUserId
           ,DateModified
           ,fkCountryId)

 
select
   left(DefaultOriginStateProvince,10) collate SQL_Latin1_General_Cp1251_CS_AS as Abbrev
   ,DefaultOriginStateProvince as StateProvinceName
   ,1 as IsActive
   ,1 as fkCreatedByUserId
   ,getdate() as DateCreated
   ,1 as fkModifiedByUserId
   ,getdate() as DateModified
   ,fkDefaultOriginCountryId
from
(   select 
   fkDefaultOriginCountryId
   ,DefaultOriginStateProvince
   ,count(*) as cnt
   from tabx.ImportStagingBrands as isb
   where IsNewStateProvince = 1
   group by fkDefaultOriginCountryId, DefaultOriginStateProvince
) sisb

--order by Abbrev asc
