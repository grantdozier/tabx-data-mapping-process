/****** Object:  Table [Common].[StateProvinceAliases]    Script Date: 5/26/2026 11:31:33 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[StateProvinceAliases](
	[pkStateProvinceAliasId] [int] IDENTITY(1,1) NOT NULL,
	[fkStateProvinceId] [int] NOT NULL,
	[StateProvinceAlias] [varchar](100) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
 CONSTRAINT [PK_StateProvinceAliases] PRIMARY KEY CLUSTERED 
(
	[pkStateProvinceAliasId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[StateProvinceAliases] ADD  CONSTRAINT [DF_StateProvinceAliases_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[StateProvinceAliases]  WITH CHECK ADD  CONSTRAINT [FK_StateProvinceAliases_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[StateProvinceAliases] CHECK CONSTRAINT [FK_StateProvinceAliases_CreatedBy]
GO

ALTER TABLE [Common].[StateProvinceAliases]  WITH CHECK ADD  CONSTRAINT [FK_StateProvinceAliases_fkStateProvinceId] FOREIGN KEY([fkStateProvinceId])
REFERENCES [Common].[StateProvinces] ([pkStateProvinceId])
GO

ALTER TABLE [Common].[StateProvinceAliases] CHECK CONSTRAINT [FK_StateProvinceAliases_fkStateProvinceId]
GO

ALTER TABLE [Common].[StateProvinceAliases]  WITH CHECK ADD  CONSTRAINT [FK_StateProvinceAliases_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[StateProvinceAliases] CHECK CONSTRAINT [FK_StateProvinceAliases_UpdatedBy]
GO

