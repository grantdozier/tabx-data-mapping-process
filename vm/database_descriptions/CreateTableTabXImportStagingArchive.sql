/****** Object:  Table [TabX].[ImportStagingArchive]    Script Date: 3/11/2026 1:26:57 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [TabX].[ImportStagingArchive](
	[pkImportStagingId] [int] NOT NULL,
	[fkLocationId] [int] NOT NULL,
	[ExternalMenuId] [varchar](500) NOT NULL,
	[TabDetailDescription] [varchar](2000) NOT NULL,
	[fkProductId] [int] NULL,
	[fkContainerId] [int] NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[RowVersionStamp] [timestamp] NOT NULL,
	[QtyOrdered] [int] NULL,
	[fkInventoryId] [int] NULL,
	[fkLocationInventoryId] [int] NULL,
UNIQUE NONCLUSTERED 
(
	[pkImportStagingId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

