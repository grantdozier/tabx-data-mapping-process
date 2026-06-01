/****** Object:  Table [Common].[UnitTypes]    Script Date: 5/26/2026 11:39:14 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[UnitTypes](
	[pkUnitTypeId] [int] NOT NULL,
	[TypeDescription] [varchar](50) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[VolumeUnits] [decimal](15, 3) NULL,
 CONSTRAINT [PK_UnitTypes] PRIMARY KEY CLUSTERED 
(
	[pkUnitTypeId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[UnitTypes] ADD  CONSTRAINT [DF_UnitTypes_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[UnitTypes]  WITH CHECK ADD  CONSTRAINT [FK_UnitTypes_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[UnitTypes] CHECK CONSTRAINT [FK_UnitTypes_CreatedBy]
GO

ALTER TABLE [Common].[UnitTypes]  WITH CHECK ADD  CONSTRAINT [FK_UnitTypes_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[UnitTypes] CHECK CONSTRAINT [FK_UnitTypes_UpdatedBy]
GO

