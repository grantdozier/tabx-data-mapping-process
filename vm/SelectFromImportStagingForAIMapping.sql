-- SelectFromImportStagingForAIMapping

-- Use to output records from ImportStaging to run through the AI lookup process
-- Copy and paste results into file: SampleInput.tsv

/*
Sample output
pkImportStagingId	LocationNameCity	ItemAsListed
16000	Golden Pony (Nashville)	1/2 Order Fries
16001	Golden Pony (Nashville)	Peach Cobbler
16002	Frankie J's (Nashville)	No Cheese

*/



SELECT [pkImportStagingId]
      ,l.Name+' ('+trim(l.City)+')' as LocationNameCity
      ,TabDetailDescription as ItemAsListed
  from TabX.ImportStaging as tis
  inner join TabX.Locations as l on (tis.fkLocationId=l.pkLocationId) 

GO
