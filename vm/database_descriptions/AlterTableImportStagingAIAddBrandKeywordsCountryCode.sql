ALTER TABLE [TabX].[ImportStagingAI]
    ADD [BrandKeywords] [varchar](255) NULL,
        [CountryCode]   [varchar](255)   NULL
GO

ALTER TABLE [TabX].[ImportStagingAIArchive]
    ADD [BrandKeywords] [varchar](255) NULL,
        [CountryCode]   [varchar](255)   NULL
GO
