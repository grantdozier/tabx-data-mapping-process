--use TabX
--go

--Purpose: Validate that archive opperation was successful

-- 650 Check Import Staging Brands table to Archive copy completed correctly
-- Should return same number of rows as previous queries

select *
from tabx.ImportStagingBrands as tisb
inner join tabx.ImportStagingBrandsArchive as tisba on (tisb.pkImportStagingBrandsId=tisba.pkImportStagingBrandsId)
--------------------------------------------
 -- where tis.fkLocationId in (57)    -- 57 Carrigan's Beer Garden

--------------------------------------------

-- and tis.pkImportStagingId in (4724, 5798, 5799, 5895, 5970, 6049, 6090, 6091, 6092, 6093, 6094, 6095, 6096, 6097, 6098, 6099, 6100, 6101, 6102, 6103, 6104, 6105, 6106, 6107, 6108, 6109, 6110, 6111, 6112, 6113, 6114, 6115, 6116, 6117, 6118, 6119) 
--



GO

