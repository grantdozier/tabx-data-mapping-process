/****** Object:  Table [TabX].[ImportStaging]    Script Date: 3/6/2026 9:52:39 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [TabX].[ImportStaging](
	[pkImportStagingId] [int] IDENTITY(1,1) NOT NULL,
	[fkLocationId] [int] NOT NULL,
	[ExternalMenuId] [varchar](500) NOT NULL,
	[TabDetailDescription] [varchar](2000) NOT NULL,
	[fkProductId] [int] NULL,
	[fkContainerId] [int] NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[RowVersionStamp] [timestamp] NOT NULL,
	[QtyOrdered] [int] NULL,
	[fkInventoryId] [int] NULL,
	[fkLocationInventoryId] [int] NULL,
	[LastSold] [int] NULL,
	[MinPrice] [decimal](12, 2) NULL,
	[MaxPrice] [decimal](12, 2) NULL,
	[NewProductName] [varchar](500) NULL,
	[IsNewProduct] [bit] NOT NULL,
	[IsNewProductAlias] [bit] NOT NULL,
	[fkProductTypeId] [int] NULL,
	[fkProductCategoryId] [int] NULL,
	[fkNewProductBrandId] [int] NULL,
	[NewProductBrand] [varchar](255) NULL,
 CONSTRAINT [PK_ImportStaging] PRIMARY KEY CLUSTERED 
(
	[pkImportStagingId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, FILLFACTOR = 100, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [TabX].[ImportStaging] ADD  DEFAULT ((0)) FOR [IsNewProduct]
GO

ALTER TABLE [TabX].[ImportStaging] ADD  DEFAULT ((0)) FOR [IsNewProductAlias]
GO

