/****** Object:  Table [Common].[BrandAliases]    Script Date: 2/26/2026 4:05:44 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[BrandAliases](
	[pkBrandAliasId] [int] IDENTITY(1,1) NOT NULL,
	[fkBrandId] [int] NOT NULL,
	[BrandAlias] [varchar](100) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
 CONSTRAINT [PK_BrandAliases] PRIMARY KEY CLUSTERED 
(
	[pkBrandAliasId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY],
UNIQUE NONCLUSTERED 
(
	[BrandAlias] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[BrandAliases] ADD  CONSTRAINT [DF_BrandAliases_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[BrandAliases]  WITH CHECK ADD  CONSTRAINT [FK_BrandAliases_Brand] FOREIGN KEY([fkBrandId])
REFERENCES [Common].[Brands] ([pkBrandId])
GO

ALTER TABLE [Common].[BrandAliases] CHECK CONSTRAINT [FK_BrandAliases_Brand]
GO

ALTER TABLE [Common].[BrandAliases]  WITH CHECK ADD  CONSTRAINT [FK_BrandAliases_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[BrandAliases] CHECK CONSTRAINT [FK_BrandAliases_CreatedBy]
GO

ALTER TABLE [Common].[BrandAliases]  WITH CHECK ADD  CONSTRAINT [FK_BrandAliases_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[BrandAliases] CHECK CONSTRAINT [FK_BrandAliases_UpdatedBy]
GO

