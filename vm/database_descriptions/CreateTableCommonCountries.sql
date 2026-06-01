/****** Object:  Table [Common].[Countries]    Script Date: 5/26/2026 11:32:03 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[Countries](
	[pkCountryId] [int] IDENTITY(1,1) NOT NULL,
	[CountryCode] [char](2) NOT NULL,
	[CountryName] [varchar](100) NOT NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[CountryCommonName] [varchar](100) NULL,
 CONSTRAINT [PK_Countries] PRIMARY KEY CLUSTERED 
(
	[pkCountryId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [Common].[Countries] ADD  CONSTRAINT [DF_Countries_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [Common].[Countries]  WITH CHECK ADD  CONSTRAINT [FK_Countries_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[Countries] CHECK CONSTRAINT [FK_Countries_CreatedBy]
GO

ALTER TABLE [Common].[Countries]  WITH CHECK ADD  CONSTRAINT [FK_Countries_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [Common].[Countries] CHECK CONSTRAINT [FK_Countries_UpdatedBy]
GO

