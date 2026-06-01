/****** Object:  Table [Common].[MixedDrinks]    Script Date: 3/6/2026 10:38:50 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[MixedDrinks](
	[pkMixedDrinkId] [int] IDENTITY(1,1) NOT NULL,
	[fkProductId] [int] NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[Official Reporting Name] [nvarchar](50) NULL,
	[MixedDrinkName] [varchar](255) NULL,
	[fkLocationId] [int] NULL,
 CONSTRAINT [PK_MixedDrinks] PRIMARY KEY CLUSTERED 
(
	[pkMixedDrinkId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, FILLFACTOR = 100, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[MixedDrinks] ADD  CONSTRAINT [DF_MixedDrinks_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[MixedDrinks]  WITH CHECK ADD  CONSTRAINT [FK_MixedDrinks_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[MixedDrinks] CHECK CONSTRAINT [FK_MixedDrinks_CreatedBy]
GO

ALTER TABLE [Common].[MixedDrinks]  WITH CHECK ADD  CONSTRAINT [FK_MixedDrinks_Locations] FOREIGN KEY([fkLocationId])
REFERENCES [TabX].[Locations] ([pkLocationId])
GO

ALTER TABLE [Common].[MixedDrinks] CHECK CONSTRAINT [FK_MixedDrinks_Locations]
GO

ALTER TABLE [Common].[MixedDrinks]  WITH CHECK ADD  CONSTRAINT [FK_MixedDrinks_Products] FOREIGN KEY([fkProductId])
REFERENCES [Common].[Products] ([pkProductId])
GO

ALTER TABLE [Common].[MixedDrinks] CHECK CONSTRAINT [FK_MixedDrinks_Products]
GO

ALTER TABLE [Common].[MixedDrinks]  WITH CHECK ADD  CONSTRAINT [FK_MixedDrinks_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[MixedDrinks] CHECK CONSTRAINT [FK_MixedDrinks_UpdatedBy]
GO

