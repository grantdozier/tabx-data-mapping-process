/****** Object:  Table [Common].[ProductTypes]    Script Date: 3/16/2026 5:35:43 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[ProductTypes](
	[pkProductTypeId] [int] IDENTITY(1,1) NOT NULL,
	[TypeDescription] [varchar](100) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[fkContainer_Default] [int] NOT NULL,
	[fkProductCategoryId_Default] [int] NOT NULL,
 CONSTRAINT [PK_ProductTypes] PRIMARY KEY CLUSTERED 
(
	[pkProductTypeId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[ProductTypes] ADD  CONSTRAINT [DF_ProductTypes_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[ProductTypes] ADD  DEFAULT ((29)) FOR [fkContainer_Default]
GO

ALTER TABLE [Common].[ProductTypes] ADD  DEFAULT ((0)) FOR [fkProductCategoryId_Default]
GO

ALTER TABLE [Common].[ProductTypes]  WITH CHECK ADD  CONSTRAINT [FK_Container_Default] FOREIGN KEY([fkContainer_Default])
REFERENCES [Common].[Containers] ([pkContainerId])
GO

ALTER TABLE [Common].[ProductTypes] CHECK CONSTRAINT [FK_Container_Default]
GO

ALTER TABLE [Common].[ProductTypes]  WITH CHECK ADD  CONSTRAINT [FK_ProductCategory_Default] FOREIGN KEY([fkProductCategoryId_Default])
REFERENCES [Common].[ProductCategories] ([pkProductCategoryId])
GO

ALTER TABLE [Common].[ProductTypes] CHECK CONSTRAINT [FK_ProductCategory_Default]
GO

ALTER TABLE [Common].[ProductTypes]  WITH CHECK ADD  CONSTRAINT [FK_ProductTypes_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[ProductTypes] CHECK CONSTRAINT [FK_ProductTypes_CreatedBy]
GO

ALTER TABLE [Common].[ProductTypes]  WITH CHECK ADD  CONSTRAINT [FK_ProductTypes_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[ProductTypes] CHECK CONSTRAINT [FK_ProductTypes_UpdatedBy]
GO


