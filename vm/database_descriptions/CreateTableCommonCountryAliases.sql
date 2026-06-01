/****** Object:  Table [Common].[CountryAliases]    Script Date: 5/26/2026 11:32:29 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[CountryAliases](
	[pkCountryAliasId] [int] IDENTITY(1,1) NOT NULL,
	[fkCountryId] [int] NOT NULL,
	[CountryAlias] [varchar](100) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
 CONSTRAINT [PK_CountryAliases] PRIMARY KEY CLUSTERED 
(
	[pkCountryAliasId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[CountryAliases] ADD  CONSTRAINT [DF_CountryAliases_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[CountryAliases]  WITH CHECK ADD  CONSTRAINT [FK_CountryAliases_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[CountryAliases] CHECK CONSTRAINT [FK_CountryAliases_CreatedBy]
GO

ALTER TABLE [Common].[CountryAliases]  WITH CHECK ADD  CONSTRAINT [FK_CountryAliases_fkCountryId] FOREIGN KEY([fkCountryId])
REFERENCES [Common].[Countries] ([pkCountryId])
GO

ALTER TABLE [Common].[CountryAliases] CHECK CONSTRAINT [FK_CountryAliases_fkCountryId]
GO

ALTER TABLE [Common].[CountryAliases]  WITH CHECK ADD  CONSTRAINT [FK_CountryAliases_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[CountryAliases] CHECK CONSTRAINT [FK_CountryAliases_UpdatedBy]
GO

