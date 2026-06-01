/****** Object:  Table [TabX].[ImportStagingBrands]    Script Date: 5/26/2026 11:29:21 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [TabX].[ImportStagingBrands](
	[pkImportStagingBrandsId] [int] IDENTITY(1,1) NOT NULL,
	[TabDetailDescription] [varchar](2000) NOT NULL,
	[Brand] [varchar](100) NOT NULL,
	[fkBrandIdExisting] [int] NULL,
	[IsInsertBrandAlias] [bit] NOT NULL,
	[IsNewBrand] [bit] NOT NULL,
	[BrandDescription] [varchar](100) NOT NULL,
	[BrandDescriptionShort] [varchar](50) NOT NULL,
	[fkParentBrandId] [int] NULL,
	[DefaultOriginCity] [varchar](100) NULL,
	[DefaultOriginCountry] [varchar](100) NULL,
	[fkDefaultOriginCountryId] [int] NOT NULL,
	[IsInsertCountryAlias] [bit] NOT NULL,
	[DefaultOriginStateProvince] [varchar](100) NULL,
	[fkDefaultOriginStateProvinceId] [int] NOT NULL,
	[IsNewStateProvince] [bit] NOT NULL,
	[IsInsertStateProvinceAlias] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[RowVersionStamp] [timestamp] NOT NULL,
 CONSTRAINT [PK_ImportStagingBrands] PRIMARY KEY CLUSTERED 
(
	[pkImportStagingBrandsId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, FILLFACTOR = 100, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

