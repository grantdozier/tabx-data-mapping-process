/****** Object:  Table [TabX].[LocationInventory]    Script Date: 3/6/2026 11:35:33 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [TabX].[LocationInventory](
	[pkLocationInventoryId] [int] IDENTITY(1,1) NOT NULL,
	[fkInventoryId] [int] NOT NULL,
	[fkLocationId] [int] NOT NULL,
	[ExternalMenuId] [varchar](500) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[TabDetailDescription] [varchar](2000) NOT NULL,
 CONSTRAINT [PK_LocationInventory] PRIMARY KEY CLUSTERED 
(
	[pkLocationInventoryId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [TabX].[LocationInventory] ADD  CONSTRAINT [DF_LocationInventory_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [TabX].[LocationInventory]  WITH CHECK ADD  CONSTRAINT [FK_LocationInventory_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [TabX].[LocationInventory] CHECK CONSTRAINT [FK_LocationInventory_CreatedBy]
GO

ALTER TABLE [TabX].[LocationInventory]  WITH CHECK ADD  CONSTRAINT [FK_LocationInventory_Inventory] FOREIGN KEY([fkInventoryId])
REFERENCES [Common].[Inventory] ([pkInventoryId])
GO

ALTER TABLE [TabX].[LocationInventory] CHECK CONSTRAINT [FK_LocationInventory_Inventory]
GO

ALTER TABLE [TabX].[LocationInventory]  WITH CHECK ADD  CONSTRAINT [FK_LocationInventory_Locations] FOREIGN KEY([fkLocationId])
REFERENCES [TabX].[Locations] ([pkLocationId])
GO

ALTER TABLE [TabX].[LocationInventory] CHECK CONSTRAINT [FK_LocationInventory_Locations]
GO

ALTER TABLE [TabX].[LocationInventory]  WITH CHECK ADD  CONSTRAINT [FK_LocationInventory_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [TabX].[LocationInventory] CHECK CONSTRAINT [FK_LocationInventory_UpdatedBy]
GO


