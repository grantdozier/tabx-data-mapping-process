/****** Object:  Table [Common].[Inventory]    Script Date: 3/6/2026 11:36:52 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[Inventory](
	[pkInventoryId] [int] IDENTITY(1,1) NOT NULL,
	[fkProductId] [int] NOT NULL,
	[fkContainerId] [int] NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[fkImportStagingId] [int] NULL,
 CONSTRAINT [PK_Inventory] PRIMARY KEY CLUSTERED 
(
	[pkInventoryId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[Inventory] ADD  CONSTRAINT [DF_Inventory_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[Inventory]  WITH CHECK ADD  CONSTRAINT [FK_Inventory_Containers] FOREIGN KEY([fkContainerId])
REFERENCES [Common].[Containers] ([pkContainerId])
GO

ALTER TABLE [Common].[Inventory] CHECK CONSTRAINT [FK_Inventory_Containers]
GO

ALTER TABLE [Common].[Inventory]  WITH CHECK ADD  CONSTRAINT [FK_Inventory_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[Inventory] CHECK CONSTRAINT [FK_Inventory_CreatedBy]
GO

ALTER TABLE [Common].[Inventory]  WITH CHECK ADD  CONSTRAINT [FK_Inventory_Products] FOREIGN KEY([fkProductId])
REFERENCES [Common].[Products] ([pkProductId])
GO

ALTER TABLE [Common].[Inventory] CHECK CONSTRAINT [FK_Inventory_Products]
GO

ALTER TABLE [Common].[Inventory]  WITH CHECK ADD  CONSTRAINT [FK_Inventory_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[Inventory] CHECK CONSTRAINT [FK_Inventory_UpdatedBy]
GO

