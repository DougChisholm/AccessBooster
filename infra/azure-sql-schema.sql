CREATE OR ALTER FUNCTION dbo.ufn_ShowingCapacity()
RETURNS smallint
WITH SCHEMABINDING
AS
BEGIN
    RETURN 50;
END;
GO

IF OBJECT_ID(N'dbo.Film', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Film
    (
        FilmId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Film PRIMARY KEY,
        FilmTitle nvarchar(50) NOT NULL,
        CONSTRAINT CK_Film_Title CHECK (LEN(LTRIM(RTRIM(FilmTitle))) BETWEEN 1 AND 50)
    );
END;
GO

IF OBJECT_ID(N'dbo.Customer', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Customer
    (
        CustID int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Customer PRIMARY KEY,
        CustName nvarchar(50) NOT NULL,
        CONSTRAINT CK_Customer_Name CHECK (LEN(LTRIM(RTRIM(CustName))) BETWEEN 1 AND 50)
    );
END;
GO

IF OBJECT_ID(N'dbo.Showing', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Showing
    (
        ShowingID int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Showing PRIMARY KEY,
        FilmId int NOT NULL,
        ShowingDate date NOT NULL,
        ShowingTime time(0) NOT NULL,
        CONSTRAINT FK_Showing_Film
            FOREIGN KEY (FilmId) REFERENCES dbo.Film (FilmId)
    );
END;
GO

IF OBJECT_ID(N'dbo.Booking', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Booking
    (
        BookingId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Booking PRIMARY KEY,
        ShowingId int NOT NULL,
        CustId int NOT NULL,
        Seats smallint NOT NULL,
        CONSTRAINT CK_Booking_Seats CHECK (Seats BETWEEN 1 AND 50),
        CONSTRAINT FK_Booking_Showing
            FOREIGN KEY (ShowingId) REFERENCES dbo.Showing (ShowingID),
        CONSTRAINT FK_Booking_Customer
            FOREIGN KEY (CustId) REFERENCES dbo.Customer (CustID)
    );
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.Showing')
      AND name = N'IX_Showing_Film_Date_Time'
)
BEGIN
    CREATE INDEX IX_Showing_Film_Date_Time
        ON dbo.Showing (FilmId, ShowingDate, ShowingTime);
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.Booking')
      AND name = N'IX_Booking_ShowingId'
)
BEGIN
    CREATE INDEX IX_Booking_ShowingId
        ON dbo.Booking (ShowingId);
END;
GO

IF NOT EXISTS
(
    SELECT 1
    FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'dbo.Booking')
      AND name = N'IX_Booking_CustId'
)
BEGIN
    CREATE INDEX IX_Booking_CustId
        ON dbo.Booking (CustId);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_FilmsAvailable
    @FromDate date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @FromDate = COALESCE(@FromDate, CONVERT(date, SYSDATETIME()));
    DECLARE @Capacity int = dbo.ufn_ShowingCapacity();

    SELECT
        s.ShowingID,
        f.FilmTitle,
        s.ShowingDate,
        s.ShowingTime,
        COUNT(b.BookingId) AS BookingCount,
        COALESCE(SUM(CONVERT(int, b.Seats)), 0) AS SeatsBooked,
        CASE
            WHEN @Capacity - COALESCE(SUM(CONVERT(int, b.Seats)), 0) < 0 THEN 0
            ELSE @Capacity - COALESCE(SUM(CONVERT(int, b.Seats)), 0)
        END AS SeatsLeft
    FROM dbo.Showing AS s
    INNER JOIN dbo.Film AS f ON f.FilmId = s.FilmId
    LEFT JOIN dbo.Booking AS b ON b.ShowingId = s.ShowingID
    WHERE s.ShowingDate >= @FromDate
    GROUP BY s.ShowingID, f.FilmTitle, s.ShowingDate, s.ShowingTime
    ORDER BY f.FilmTitle, s.ShowingDate, s.ShowingTime;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCustomers
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CustID, CustName
    FROM dbo.Customer
    ORDER BY CustName;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetSeatAvailability
    @ShowingId int,
    @FromDate date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @FromDate = COALESCE(@FromDate, CONVERT(date, SYSDATETIME()));
    DECLARE @Capacity int = dbo.ufn_ShowingCapacity();

    SELECT
        COUNT(b.BookingId) AS BookingCount,
        COALESCE(SUM(CONVERT(int, b.Seats)), 0) AS SeatsBooked,
        CASE
            WHEN @Capacity - COALESCE(SUM(CONVERT(int, b.Seats)), 0) < 0 THEN 0
            ELSE @Capacity - COALESCE(SUM(CONVERT(int, b.Seats)), 0)
        END AS SeatsLeft
    FROM dbo.Showing AS s
    LEFT JOIN dbo.Booking AS b ON b.ShowingId = s.ShowingID
    WHERE s.ShowingID = @ShowingId
      AND s.ShowingDate >= @FromDate
    GROUP BY s.ShowingID;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetRecentBookings
    @Take int = 10
AS
BEGIN
    SET NOCOUNT ON;
    SET @Take = CASE WHEN @Take < 1 THEN 1 WHEN @Take > 100 THEN 100 ELSE @Take END;

    SELECT TOP (@Take)
        b.BookingId,
        c.CustName,
        f.FilmTitle,
        s.ShowingDate,
        s.ShowingTime,
        b.Seats
    FROM dbo.Booking AS b
    INNER JOIN dbo.Customer AS c ON c.CustID = b.CustId
    INNER JOIN dbo.Showing AS s ON s.ShowingID = b.ShowingId
    INNER JOIN dbo.Film AS f ON f.FilmId = s.FilmId
    ORDER BY b.BookingId DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_CreateBooking
    @ShowingId int,
    @CustomerId int,
    @Seats smallint,
    @FromDate date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @FromDate = COALESCE(@FromDate, CONVERT(date, SYSDATETIME()));
    DECLARE @Capacity int = dbo.ufn_ShowingCapacity();

    IF @ShowingId <= 0 OR @CustomerId <= 0
        THROW 50001, 'Select a showing and customer.', 1;

    IF @Seats < 1 OR @Seats > @Capacity
        THROW 50002, 'The requested seat count is outside the allowed range.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @ShowingDate date;
        SELECT @ShowingDate = ShowingDate
        FROM dbo.Showing WITH (UPDLOCK, HOLDLOCK)
        WHERE ShowingID = @ShowingId;

        IF @ShowingDate IS NULL OR @ShowingDate < @FromDate
            THROW 50003, 'The selected showing is no longer available.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.Customer WITH (HOLDLOCK)
            WHERE CustID = @CustomerId
        )
            THROW 50004, 'The selected customer does not exist.', 1;

        DECLARE @SeatsBooked int;
        SELECT @SeatsBooked = COALESCE(SUM(CONVERT(int, Seats)), 0)
        FROM dbo.Booking WITH (UPDLOCK, HOLDLOCK)
        WHERE ShowingId = @ShowingId;

        DECLARE @SeatsLeft int = @Capacity - @SeatsBooked;
        IF @Seats > @SeatsLeft
            THROW 50005, 'There are not enough seats available for this booking.', 1;

        INSERT dbo.Booking (ShowingId, CustId, Seats)
        VALUES (@ShowingId, @CustomerId, @Seats);

        DECLARE @BookingId int = CONVERT(int, SCOPE_IDENTITY());
        SET @SeatsLeft -= @Seats;

        COMMIT TRANSACTION;

        SELECT @BookingId AS BookingId, @SeatsLeft AS SeatsLeft;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_SeedDemoData
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRANSACTION;

    SET IDENTITY_INSERT dbo.Film ON;
    MERGE dbo.Film AS target
    USING
    (
        VALUES
            (1, N'The Last Lighthouse'),
            (2, N'Orbiting Home'),
            (3, N'A Map of Small Wonders'),
            (4, N'Midnight at the Arcade')
    ) AS source (FilmId, FilmTitle)
    ON target.FilmId = source.FilmId
    WHEN NOT MATCHED THEN
        INSERT (FilmId, FilmTitle) VALUES (source.FilmId, source.FilmTitle);
    SET IDENTITY_INSERT dbo.Film OFF;

    SET IDENTITY_INSERT dbo.Customer ON;
    MERGE dbo.Customer AS target
    USING
    (
        VALUES
            (1, N'Avery Morgan'),
            (2, N'Jordan Lee'),
            (3, N'Samira Patel'),
            (4, N'Diego Santos')
    ) AS source (CustID, CustName)
    ON target.CustID = source.CustID
    WHEN NOT MATCHED THEN
        INSERT (CustID, CustName) VALUES (source.CustID, source.CustName);
    SET IDENTITY_INSERT dbo.Customer OFF;

    SET IDENTITY_INSERT dbo.Showing ON;
    MERGE dbo.Showing AS target
    USING
    (
        VALUES
            (1, 1, DATEADD(day, 1, CONVERT(date, SYSDATETIME())), CONVERT(time(0), '18:30:00')),
            (2, 2, DATEADD(day, 1, CONVERT(date, SYSDATETIME())), CONVERT(time(0), '20:15:00')),
            (3, 3, DATEADD(day, 2, CONVERT(date, SYSDATETIME())), CONVERT(time(0), '17:45:00')),
            (4, 1, DATEADD(day, 3, CONVERT(date, SYSDATETIME())), CONVERT(time(0), '21:00:00')),
            (5, 4, DATEADD(day, 4, CONVERT(date, SYSDATETIME())), CONVERT(time(0), '19:30:00'))
    ) AS source (ShowingID, FilmId, ShowingDate, ShowingTime)
    ON target.ShowingID = source.ShowingID
    WHEN NOT MATCHED THEN
        INSERT (ShowingID, FilmId, ShowingDate, ShowingTime)
        VALUES (source.ShowingID, source.FilmId, source.ShowingDate, source.ShowingTime);
    SET IDENTITY_INSERT dbo.Showing OFF;

    SET IDENTITY_INSERT dbo.Booking ON;
    MERGE dbo.Booking AS target
    USING
    (
        VALUES
            (1, 1, 1, CONVERT(smallint, 4)),
            (2, 1, 2, CONVERT(smallint, 2)),
            (3, 2, 3, CONVERT(smallint, 5)),
            (4, 3, 4, CONVERT(smallint, 2))
    ) AS source (BookingId, ShowingId, CustId, Seats)
    ON target.BookingId = source.BookingId
    WHEN NOT MATCHED THEN
        INSERT (BookingId, ShowingId, CustId, Seats)
        VALUES (source.BookingId, source.ShowingId, source.CustId, source.Seats);
    SET IDENTITY_INSERT dbo.Booking OFF;

    COMMIT TRANSACTION;
END;
GO

EXEC dbo.usp_SeedDemoData;
GO
