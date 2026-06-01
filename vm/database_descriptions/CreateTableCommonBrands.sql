/****** Object:  Table [Common].[Brands]    Script Date: 2/26/2026 4:05:23 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[Brands](
	[pkBrandId] [int] IDENTITY(1,1) NOT NULL,
	[BrandDescription] [varchar](100) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[DefaultOriginCity] [varchar](100) NULL,
	[fkDefaultOriginCountryId] [int] NOT NULL,
	[fkDefaultOriginStateProvinceId] [int] NOT NULL,
	[BrandDescriptionShort] [varchar](50) NOT NULL,
	[fkParentBrandId] [int] NULL,
	[fkDefaultProductId] [int] NULL,
 CONSTRAINT [PK_Brands] PRIMARY KEY CLUSTERED 
(
	[pkBrandId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, FILLFACTOR = 100, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[Brands] ADD  CONSTRAINT [DF_Brands_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[Brands] ADD  DEFAULT ((1)) FOR [fkDefaultOriginCountryId]
GO

ALTER TABLE [Common].[Brands] ADD  DEFAULT ((1)) FOR [fkDefaultOriginStateProvinceId]
GO

ALTER TABLE [Common].[Brands] ADD  DEFAULT ('') FOR [BrandDescriptionShort]
GO

ALTER TABLE [Common].[Brands]  WITH CHECK ADD  CONSTRAINT [FK_Brands_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[Brands] CHECK CONSTRAINT [FK_Brands_CreatedBy]
GO

ALTER TABLE [Common].[Brands]  WITH CHECK ADD  CONSTRAINT [FK_Brands_OriginCountries] FOREIGN KEY([fkDefaultOriginCountryId])
REFERENCES [Common].[Countries] ([pkCountryId])
GO

ALTER TABLE [Common].[Brands] CHECK CONSTRAINT [FK_Brands_OriginCountries]
GO

ALTER TABLE [Common].[Brands]  WITH CHECK ADD  CONSTRAINT [FK_Brands_OriginStateProvinces] FOREIGN KEY([fkDefaultOriginStateProvinceId])
REFERENCES [Common].[StateProvinces] ([pkStateProvinceId])
GO

ALTER TABLE [Common].[Brands] CHECK CONSTRAINT [FK_Brands_OriginStateProvinces]
GO

ALTER TABLE [Common].[Brands]  WITH CHECK ADD  CONSTRAINT [FK_Brands_ParentBrand] FOREIGN KEY([fkParentBrandId])
REFERENCES [Common].[Brands] ([pkBrandId])
GO

ALTER TABLE [Common].[Brands] CHECK CONSTRAINT [FK_Brands_ParentBrand]
GO

ALTER TABLE [Common].[Brands]  WITH CHECK ADD  CONSTRAINT [FK_Brands_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[Brands] CHECK CONSTRAINT [FK_Brands_UpdatedBy]
GO

