/****** Object:  Table [Common].[StateProvinces]    Script Date: 5/26/2026 11:31:07 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[StateProvinces](
	[pkStateProvinceId] [int] IDENTITY(1,1) NOT NULL,
	[Abbrev] [varchar](10) NULL,
	[StateProvinceName] [varchar](100) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[fkCountryId] [int] NOT NULL,
 CONSTRAINT [PK_StateProvinces] PRIMARY KEY CLUSTERED 
(
	[pkStateProvinceId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[StateProvinces] ADD  CONSTRAINT [DF_StateProvinces_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[StateProvinces] ADD  DEFAULT ((1)) FOR [fkCountryId]
GO

ALTER TABLE [Common].[StateProvinces]  WITH CHECK ADD  CONSTRAINT [FK_StateProvinces_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[StateProvinces] CHECK CONSTRAINT [FK_StateProvinces_CreatedBy]
GO

ALTER TABLE [Common].[StateProvinces]  WITH CHECK ADD  CONSTRAINT [FK_StateProvinces_fkCountryId] FOREIGN KEY([fkCountryId])
REFERENCES [Common].[Countries] ([pkCountryId])
GO

ALTER TABLE [Common].[StateProvinces] CHECK CONSTRAINT [FK_StateProvinces_fkCountryId]
GO

ALTER TABLE [Common].[StateProvinces]  WITH CHECK ADD  CONSTRAINT [FK_StateProvinces_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[StateProvinces] CHECK CONSTRAINT [FK_StateProvinces_UpdatedBy]
GO

