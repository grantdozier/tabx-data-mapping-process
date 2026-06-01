/****** Object:  Table [Common].[Products]    Script Date: 2/26/2026 4:06:26 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[Products](
	[pkProductId] [int] IDENTITY(1,1) NOT NULL,
	[fkBrandId] [int] NULL,
	[fkProductTypeId] [int] NOT NULL,
	[fkProductCategoryId] [int] NOT NULL,
	[ProductName] [varchar](1000) NOT NULL,
	[ABV] [decimal](5, 2) NULL,
	[fkOriginCountryId] [int] NULL,
	[fkOriginStateProvinceId] [int] NULL,
	[OriginCity] [varchar](100) NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[fkCommonId] [int] NULL,
	[DEPfkBeerId] [int] NULL,
	[DEPfkLiquorId] [int] NULL,
	[DEPfkMixedDrinkId] [int] NULL,
	[fkProductionScaleId] [int] NULL,
	[RowVersionStamp] [timestamp] NOT NULL,
 CONSTRAINT [PK_ProductsNew] PRIMARY KEY CLUSTERED 
(
	[pkProductId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, FILLFACTOR = 100, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[Products] ADD  CONSTRAINT [DF_ProductsNew_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[Products]  WITH CHECK ADD  CONSTRAINT [FK_Products_ProductionScale] FOREIGN KEY([fkProductionScaleId])
REFERENCES [Common].[ProductionScales] ([pkProductionScaleId])
GO

ALTER TABLE [Common].[Products] CHECK CONSTRAINT [FK_Products_ProductionScale]
GO

ALTER TABLE [Common].[Products]  WITH CHECK ADD  CONSTRAINT [FK_ProductsNew_Brands] FOREIGN KEY([fkBrandId])
REFERENCES [Common].[Brands] ([pkBrandId])
GO

ALTER TABLE [Common].[Products] CHECK CONSTRAINT [FK_ProductsNew_Brands]
GO

ALTER TABLE [Common].[Products]  WITH CHECK ADD  CONSTRAINT [FK_ProductsNew_Countries] FOREIGN KEY([fkOriginCountryId])
REFERENCES [Common].[Countries] ([pkCountryId])
GO

ALTER TABLE [Common].[Products] CHECK CONSTRAINT [FK_ProductsNew_Countries]
GO

ALTER TABLE [Common].[Products]  WITH CHECK ADD  CONSTRAINT [FK_ProductsNew_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[Products] CHECK CONSTRAINT [FK_ProductsNew_CreatedBy]
GO

ALTER TABLE [Common].[Products]  WITH CHECK ADD  CONSTRAINT [FK_ProductsNew_StateProvinces] FOREIGN KEY([fkOriginStateProvinceId])
REFERENCES [Common].[StateProvinces] ([pkStateProvinceId])
GO

ALTER TABLE [Common].[Products] CHECK CONSTRAINT [FK_ProductsNew_StateProvinces]
GO

ALTER TABLE [Common].[Products]  WITH CHECK ADD  CONSTRAINT [FK_ProductsNew_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[Products] CHECK CONSTRAINT [FK_ProductsNew_UpdatedBy]
GO

