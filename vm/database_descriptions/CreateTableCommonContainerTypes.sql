/****** Object:  Table [Common].[ContainerTypes]    Script Date: 5/26/2026 11:35:17 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[ContainerTypes](
	[pkContainerTypeId] [int] IDENTITY(1,1) NOT NULL,
	[TypeDescription] [varchar](100) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
 CONSTRAINT [PK_ContainerTypes] PRIMARY KEY CLUSTERED 
(
	[pkContainerTypeId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[ContainerTypes] ADD  CONSTRAINT [DF_ContainerTypes_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[ContainerTypes]  WITH CHECK ADD  CONSTRAINT [FK_ContainerTypes_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[ContainerTypes] CHECK CONSTRAINT [FK_ContainerTypes_CreatedBy]
GO

ALTER TABLE [Common].[ContainerTypes]  WITH CHECK ADD  CONSTRAINT [FK_ContainerTypes_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[ContainerTypes] CHECK CONSTRAINT [FK_ContainerTypes_UpdatedBy]
GO

