/****** Object:  Table [Common].[ProductCategories]    Script Date: 2/26/2026 4:08:03 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[ProductCategories](
	[pkProductCategoryId] [int] IDENTITY(1,1) NOT NULL,
	[fkParentCategoryId] [int] NULL,
	[CategoryName] [varchar](1000) NOT NULL,
	[SortOrder] [int] NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[DefaultABV] [decimal](5, 2) NULL,
	[DefaultfkContainerId] [int] NULL,
 CONSTRAINT [PK_ProductCategories] PRIMARY KEY CLUSTERED 
(
	[pkProductCategoryId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[ProductCategories]  WITH CHECK ADD  CONSTRAINT [FK_ProductCategories_Containers] FOREIGN KEY([DefaultfkContainerId])
REFERENCES [Common].[Containers] ([pkContainerId])
GO

ALTER TABLE [Common].[ProductCategories] CHECK CONSTRAINT [FK_ProductCategories_Containers]
GO

ALTER TABLE [Common].[ProductCategories]  WITH CHECK ADD  CONSTRAINT [FK_ProductCategories_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[ProductCategories] CHECK CONSTRAINT [FK_ProductCategories_CreatedBy]
GO

ALTER TABLE [Common].[ProductCategories]  WITH CHECK ADD  CONSTRAINT [FK_ProductCategories_ParentCategory] FOREIGN KEY([fkParentCategoryId])
REFERENCES [Common].[ProductCategories] ([pkProductCategoryId])
GO

ALTER TABLE [Common].[ProductCategories] CHECK CONSTRAINT [FK_ProductCategories_ParentCategory]
GO

ALTER TABLE [Common].[ProductCategories]  WITH CHECK ADD  CONSTRAINT [FK_ProductCategories_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[ProductCategories] CHECK CONSTRAINT [FK_ProductCategories_UpdatedBy]
GO

