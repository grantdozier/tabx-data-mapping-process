/****** Object:  Table [Common].[MixedDrinkCompositions]    Script Date: 5/26/2026 11:35:52 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[MixedDrinkCompositions](
	[pkMixedDrinkCompositionId] [int] IDENTITY(1,1) NOT NULL,
	[fkMixedDrinkId] [int] NOT NULL,
	[fkProductId] [int] NOT NULL,
	[Units] [decimal](15, 3) NOT NULL,
	[fkUnitTypeId] [int] NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
 CONSTRAINT [PK_MixedDrinkCompositions] PRIMARY KEY CLUSTERED 
(
	[pkMixedDrinkCompositionId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, FILLFACTOR = 100, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[MixedDrinkCompositions] ADD  CONSTRAINT [DF_MixedDrinkCompositions_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[MixedDrinkCompositions]  WITH CHECK ADD  CONSTRAINT [FK_MixedDrinkCompositions_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[MixedDrinkCompositions] CHECK CONSTRAINT [FK_MixedDrinkCompositions_CreatedBy]
GO

ALTER TABLE [Common].[MixedDrinkCompositions]  WITH CHECK ADD  CONSTRAINT [FK_MixedDrinkCompositions_MixedDrinks] FOREIGN KEY([fkMixedDrinkId])
REFERENCES [Common].[MixedDrinks] ([pkMixedDrinkId])
GO

ALTER TABLE [Common].[MixedDrinkCompositions] CHECK CONSTRAINT [FK_MixedDrinkCompositions_MixedDrinks]
GO

ALTER TABLE [Common].[MixedDrinkCompositions]  WITH CHECK ADD  CONSTRAINT [FK_MixedDrinkCompositions_Products] FOREIGN KEY([fkProductId])
REFERENCES [Common].[Products] ([pkProductId])
GO

ALTER TABLE [Common].[MixedDrinkCompositions] CHECK CONSTRAINT [FK_MixedDrinkCompositions_Products]
GO

ALTER TABLE [Common].[MixedDrinkCompositions]  WITH CHECK ADD  CONSTRAINT [FK_MixedDrinkCompositions_UnitTypes] FOREIGN KEY([fkUnitTypeId])
REFERENCES [Common].[UnitTypes] ([pkUnitTypeId])
GO

ALTER TABLE [Common].[MixedDrinkCompositions] CHECK CONSTRAINT [FK_MixedDrinkCompositions_UnitTypes]
GO

ALTER TABLE [Common].[MixedDrinkCompositions]  WITH CHECK ADD  CONSTRAINT [FK_MixedDrinkCompositions_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[MixedDrinkCompositions] CHECK CONSTRAINT [FK_MixedDrinkCompositions_UpdatedBy]
GO


