/****** Object:  Table [Common].[ProductionScales]    Script Date: 5/26/2026 11:38:17 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [Common].[ProductionScales](
	[pkProductionScaleId] [int] IDENTITY(1,1) NOT NULL,
	[ProductionScaleDescription] [varchar](255) NULL,
 CONSTRAINT [PK_ProductionScale] PRIMARY KEY CLUSTERED 
(
	[pkProductionScaleId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

