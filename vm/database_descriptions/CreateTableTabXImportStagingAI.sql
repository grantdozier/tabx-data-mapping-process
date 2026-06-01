/****** Object:  Table [TabX].[ImportStagingAI]    Script Date: 2/26/2026 4:04:25 PM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [TabX].[ImportStagingAI](
	[pkImportStagingAIId] [int] IDENTITY(1,1) NOT NULL,
	[fkImportStagingId] [int] NOT NULL,
	[ItemAsListed] [varchar](2000) NOT NULL,
	[Brand] [varchar](255) NULL,
	[ProductName] [varchar](255) NULL,
	[ContainerSizeQty] [varchar](255) NULL,
	[ContainerSizeUnit] [varchar](255) NULL,
	[ContainerType] [varchar](255) NULL,
	[ABV] [varchar](255) NULL,
	[ProductType] [varchar](255) NULL,
	[ProductCategory] [varchar](255) NULL,
	[Country] [varchar](255) NULL,
	[City] [varchar](255) NULL,
	[StateProv] [varchar](255) NULL,
 CONSTRAINT [PK_ImportStagingAI] PRIMARY KEY CLUSTERED 
(
	[pkImportStagingAIId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, FILLFACTOR = 100, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

