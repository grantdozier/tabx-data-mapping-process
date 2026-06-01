/****** Object:  Table [TabX].[ImportStagingAIArchive]    Script Date: 5/26/2026 11:48:46 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [TabX].[ImportStagingAIArchive](
	[pkImportStagingAIId] [int] IDENTITY(1,1) NOT NULL,
	[ItemAsListed] [varchar](2000) NOT NULL,
	[Brand] [varchar](255) NULL,
	[ProductName] [varchar](255) NULL,
	[ContainerSizeQty] [varchar](255) NULL,
	[ContainerSizeUnit] [varchar](255) NULL,
	[ContainerType] [varchar](255) NULL,
	[ABV] [varchar](255) NULL,
	[ProductType] [varchar](255) NULL,
	[ProductCategory] [varchar](255) NULL,
	[Country] [varchar](255) NULL,
	[City] [varchar](255) NULL,
	[StateProv] [varchar](255) NULL,
	[fkImportStagingId] [int] NULL,
	[BrandNameShort] [varchar](255) NULL,
	[ProductKeywords] [varchar](500) NULL,
	[IsWellKnownMixedDrink] [bit] NULL
) ON [PRIMARY]
GO

