/****** Object:  Table [TabX].[Locations]    Script Date: 3/3/2026 10:55:34 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [TabX].[Locations](
	[pkLocationId] [int] IDENTITY(1,1) NOT NULL,
	[Name] [varchar](100) NOT NULL,
	[Address1] [varchar](100) NOT NULL,
	[Address2] [varchar](100) NULL,
	[City] [varchar](50) NOT NULL,
	[State] [char](2) NOT NULL,
	[ZipCode] [varchar](10) NOT NULL,
	[Latitude] [float] NOT NULL,
	[Longitude] [float] NOT NULL,
	[Description] [varchar](2000) NULL,
	[IsActive] [bit] NOT NULL,
	[fkCreatedByUserId] [int] NOT NULL,
	[DateCreated] [datetime] NOT NULL,
	[fkModifiedByUserId] [int] NOT NULL,
	[DateModified] [datetime] NOT NULL,
	[PhoneNumber] [varchar](25) NOT NULL,
	[fkPosSystemId] [int] NOT NULL,
	[fkPaymentProcessorId] [int] NOT NULL,
	[TimezoneId] [varchar](50) NOT NULL,
	[SettingsHandler] [varchar](100) NULL,
	[LastCallDateRequested] [datetime] NULL,
	[fkLastCallRequestedByUserId] [int] NULL,
	[LastCallDurationMins] [int] NULL,
	[LastCallBufferMins] [int] NULL,
	[LastCallNotifyUsers] [bit] NULL,
	[LastPosUpdate] [datetime] NULL,
	[TipPercent1] [decimal](6, 3) NULL,
	[TipPercent2] [decimal](6, 3) NULL,
	[TipPercent3] [decimal](6, 3) NULL,
	[TipPercentLastCall] [decimal](6, 3) NULL,
	[StripeConnectAccountId] [varchar](50) NULL,
	[StripeConnectCustomerId] [varchar](50) NULL,
	[GooglePlaceId] [varchar](300) NULL,
	[StripeConnectedDate] [datetime] NULL,
	[StripeEmail] [nvarchar](255) NULL,
 CONSTRAINT [PK_Locations] PRIMARY KEY CLUSTERED 
(
	[pkLocationId] ASC
)WITH (STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, FILLFACTOR = 100, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [TabX].[Locations] ADD  CONSTRAINT [DF_Locations_IsActive]  DEFAULT ((1)) FOR [IsActive]
GO

ALTER TABLE [TabX].[Locations]  WITH NOCHECK ADD  CONSTRAINT [FK_Locations_CreatedBy] FOREIGN KEY([fkCreatedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [TabX].[Locations] CHECK CONSTRAINT [FK_Locations_CreatedBy]
GO

ALTER TABLE [TabX].[Locations]  WITH NOCHECK ADD  CONSTRAINT [FK_Locations_LastCallRequestedBy] FOREIGN KEY([fkLastCallRequestedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [TabX].[Locations] CHECK CONSTRAINT [FK_Locations_LastCallRequestedBy]
GO

ALTER TABLE [TabX].[Locations]  WITH NOCHECK ADD  CONSTRAINT [FK_Locations_PaymentProcessors] FOREIGN KEY([fkPaymentProcessorId])
REFERENCES [TabX].[PaymentProcessors] ([pkPaymentProcessorId])
GO

ALTER TABLE [TabX].[Locations] CHECK CONSTRAINT [FK_Locations_PaymentProcessors]
GO

ALTER TABLE [TabX].[Locations]  WITH NOCHECK ADD  CONSTRAINT [FK_Locations_PosSystems] FOREIGN KEY([fkPosSystemId])
REFERENCES [TabX].[PosSystems] ([pkPosSystemId])
GO

ALTER TABLE [TabX].[Locations] CHECK CONSTRAINT [FK_Locations_PosSystems]
GO

ALTER TABLE [TabX].[Locations]  WITH NOCHECK ADD  CONSTRAINT [FK_Locations_UpdatedBy] FOREIGN KEY([fkModifiedByUserId])
REFERENCES [TabX].[Users] ([pkUserId])
GO

ALTER TABLE [TabX].[Locations] CHECK CONSTRAINT [FK_Locations_UpdatedBy]
GO

