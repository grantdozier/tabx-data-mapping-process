--USE TabX
--GO

-- Step s0200: Insert new country aliases from ImportStagingBrands
--
-- Inserts rows into Common.CountryAliases for ImportStagingBrands rows
-- where IsInsertCountryAlias = 1.
--
-- Unlike state/provinces (s0100/s0150), countries are not inserted through this
-- process — there is no IsNewCountry flag and no preceding InsertNewCountries step.
-- fkDefaultOriginCountryId is therefore always populated on the staging row,
-- and DefaultOriginCountry (the raw import text) becomes the alias value.

/*
INSERT INTO Common.CountryAliases
           (fkCountryId
           ,CountryAlias
           ,IsActive
           ,fkCreatedByUserId
           ,DateCreated
           ,fkModifiedByUserId
           ,DateModified)
*/
-- Aliases for existing countries.
-- fkDefaultOriginCountryId is always populated since new countries are not
-- created through this process; use it directly as the FK.
SELECT
   fkDefaultOriginCountryId as fkCountryId
   ,DefaultOriginCountry as CountryAlias
   ,1 as IsActive
   ,1 as fkCreatedByUserId
   ,getdate() as DateCreated
   ,1 as fkModifiedByUserId
   ,getdate() as DateModified
from
(  select
      DefaultOriginCountry
      ,fkDefaultOriginCountryId
   from tabx.ImportStagingBrands as isb
   where IsInsertCountryAlias = 1
   and DefaultOriginCountry is not null
   -- skip aliases that already exist in Common.CountryAliases
   and not exists (
      select 1 from Common.CountryAliases ca
      where lower(trim(ca.CountryAlias collate SQL_Latin1_General_Cp1251_CS_AS))
          = lower(trim(isb.DefaultOriginCountry collate SQL_Latin1_General_Cp1251_CS_AS))
   )
) sisb

GO
