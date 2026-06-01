--USE TabX
--GO

-- Step s0150: Insert new state/province aliases from ImportStagingBrands
--
-- Runs after:
--   s0100 - which inserts any new state/province records into Common.StateProvinces
--
-- Inserts rows into Common.StateProvinceAliases for ImportStagingBrands rows
-- where IsInsertStateProvinceAlias = 1. Two cases are handled:
--
--   1. Existing state/province: fkDefaultOriginStateProvinceId is already populated
--      on the staging row, so it is used directly as the FK.
--
--   2. Newly created state/province (IsNewStateProvince = 1): the staging row does not
--      yet have fkDefaultOriginStateProvinceId populated, so we look up the record
--      just inserted by s0100 via StateProvinceName + fkCountryId.
--
-- In both cases DefaultOriginStateProvince (the raw import text) becomes the alias value,
-- mapping an alternate name to the canonical Common.StateProvinces record.


INSERT INTO Common.StateProvinceAliases
           (fkStateProvinceId
           ,StateProvinceAlias
           ,IsActive
           ,fkCreatedByUserId
           ,DateCreated
           ,fkModifiedByUserId
           ,DateModified




-- Case 1: Aliases for existing state/provinces.
-- fkDefaultOriginStateProvinceId is populated on the staging row, so use it directly.
SELECT
   fkDefaultOriginStateProvinceId as fkStateProvinceId
   ,DefaultOriginStateProvince as StateProvinceAlias
   ,1 as IsActive
   ,1 as fkCreatedByUserId
   ,getdate() as DateCreated
   ,1 as fkModifiedByUserId
   ,getdate() as DateModified
from
(  select
      DefaultOriginStateProvince
      ,fkDefaultOriginStateProvinceId
      ,fkDefaultOriginCountryId
   from tabx.ImportStagingBrands as isb
   where IsInsertStateProvinceAlias = 1
   and IsNewStateProvince = 0   -- existing state/province; FK already known
   and DefaultOriginStateProvince is not null
) sisb

union all

-- Case 2: Aliases for newly created state/provinces (inserted by s0100).
-- fkDefaultOriginStateProvinceId is not yet populated on the staging row, so join
-- Common.StateProvinces by name and country to find the record s0100 just created.
SELECT
   sp.pkStateProvinceId as fkStateProvinceId
   ,sisb.DefaultOriginStateProvince as StateProvinceAlias
   ,1 as IsActive
   ,1 as fkCreatedByUserId
   ,getdate() as DateCreated
   ,1 as fkModifiedByUserId
   ,getdate() as DateModified
from
(  select
      DefaultOriginStateProvince
      ,fkDefaultOriginCountryId
   from tabx.ImportStagingBrands as isb
   where IsInsertStateProvinceAlias = 1
   and IsNewStateProvince = 1   -- new state/province; must look up FK from Common.StateProvinces
   and DefaultOriginStateProvince is not null
) sisb
inner join Common.StateProvinces as sp
   on sisb.DefaultOriginStateProvince = sp.StateProvinceName
   and sisb.fkDefaultOriginCountryId = sp.fkCountryId
   and sp.IsActive = 1

GO
