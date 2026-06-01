/****** Object:  Table [Common].[ProductAliases]    Script Date: 2/26/2026 4:06:54 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[ProductAliases](
	[pkProductAliasId] [int] IDENTITY(1,1) NOT NULL,
	[fkProductId] [int] NOT NULL,
	[ProductAlias] [varchar](100) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
 CONSTRAINT [PK_ProductAliases] PRIMARY KEY CLUSTERED 
(
	[pkProductAliasId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[ProductAliases] ADD  CONSTRAINT [DF_ProductAliases_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[ProductAliases]  WITH CHECK ADD  CONSTRAINT [FK_ProductAliases_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[ProductAliases] CHECK CONSTRAINT [FK_ProductAliases_CreatedBy]
GO

ALTER TABLE [Common].[ProductAliases]  WITH CHECK ADD  CONSTRAINT [FK_ProductAliases_fkProductId] FOREIGN KEY([fkProductId])
REFERENCES [Common].[Products] ([pkProductId])
GO

ALTER TABLE [Common].[ProductAliases] CHECK CONSTRAINT [FK_ProductAliases_fkProductId]
GO

ALTER TABLE [Common].[ProductAliases]  WITH CHECK ADD  CONSTRAINT [FK_ProductAliases_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[ProductAliases] CHECK CONSTRAINT [FK_ProductAliases_UpdatedBy]
GO

