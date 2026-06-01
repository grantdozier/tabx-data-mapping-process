/****** Object:  Table [Common].[Containers]    Script Date: 5/26/2026 11:34:59 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[Containers](
	[pkContainerId] [int] IDENTITY(1,1) NOT NULL,
	[ContainerDescription] [varchar](100) NOT NULL,
	[fkContainerTypeId] [int] NOT NULL,
	[VolumeUnits] [decimal](15, 3) NOT NULL,
	[fkUnitTypeId] [int] NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
 CONSTRAINT [PK_Containers] PRIMARY KEY CLUSTERED 
(
	[pkContainerId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[Containers] ADD  CONSTRAINT [DF_Containers_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[Containers]  WITH CHECK ADD  CONSTRAINT [FK_Containers_ContainerTypes] FOREIGN KEY([fkContainerTypeId])
REFERENCES [Common].[ContainerTypes] ([pkContainerTypeId])
GO

ALTER TABLE [Common].[Containers] CHECK CONSTRAINT [FK_Containers_ContainerTypes]
GO

ALTER TABLE [Common].[Containers]  WITH CHECK ADD  CONSTRAINT [FK_Containers_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[Containers] CHECK CONSTRAINT [FK_Containers_CreatedBy]
GO

ALTER TABLE [Common].[Containers]  WITH CHECK ADD  CONSTRAINT [FK_Containers_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[Containers] CHECK CONSTRAINT [FK_Containers_UpdatedBy]
GO

