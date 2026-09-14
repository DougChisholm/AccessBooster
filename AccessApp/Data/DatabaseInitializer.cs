using System.Globalization;
using Microsoft.Data.Sqlite;

namespace AccessApp.Data;

public sealed class DatabaseInitializer(
    ISqliteConnectionFactory connectionFactory,
    TimeProvider timeProvider,
    ILogger<DatabaseInitializer> logger)
{
    private const string SchemaSql = """
        CREATE TABLE IF NOT EXISTS Film (
            FilmId INTEGER NOT NULL CONSTRAINT PK_Film PRIMARY KEY,
            FilmTitle TEXT NOT NULL CONSTRAINT CK_Film_Title CHECK (length(trim(FilmTitle)) BETWEEN 1 AND 50)
        );

        CREATE TABLE IF NOT EXISTS Customer (
            CustID INTEGER NOT NULL CONSTRAINT PK_Customer PRIMARY KEY,
            CustName TEXT NOT NULL CONSTRAINT CK_Customer_Name CHECK (length(trim(CustName)) BETWEEN 1 AND 50)
        );

        CREATE TABLE IF NOT EXISTS Showing (
            ShowingID INTEGER NOT NULL CONSTRAINT PK_Showing PRIMARY KEY,
            FilmId INTEGER NOT NULL,
            ShowingDate TEXT NOT NULL,
            ShowingTime TEXT NOT NULL,
            CONSTRAINT FK_Showing_Film FOREIGN KEY (FilmId) REFERENCES Film (FilmId)
        );

        CREATE TABLE IF NOT EXISTS Booking (
            BookingId INTEGER NOT NULL CONSTRAINT PK_Booking PRIMARY KEY AUTOINCREMENT,
            ShowingId INTEGER NOT NULL,
            CustId INTEGER NOT NULL,
            Seats INTEGER NOT NULL CONSTRAINT CK_Booking_Seats CHECK (Seats BETWEEN 1 AND 50),
            CONSTRAINT FK_Booking_Showing FOREIGN KEY (ShowingId) REFERENCES Showing (ShowingID),
            CONSTRAINT FK_Booking_Customer FOREIGN KEY (CustId) REFERENCES Customer (CustID)
        );

        CREATE INDEX IF NOT EXISTS IX_Showing_Film_Date_Time
            ON Showing (FilmId, ShowingDate, ShowingTime);
        CREATE INDEX IF NOT EXISTS IX_Booking_ShowingId
            ON Booking (ShowingId);
        CREATE INDEX IF NOT EXISTS IX_Booking_CustId
            ON Booking (CustId);
        """;

    private const string InsertFilmSql =
        "INSERT OR IGNORE INTO Film (FilmId, FilmTitle) VALUES ($filmId, $filmTitle);";

    private const string InsertCustomerSql =
        "INSERT OR IGNORE INTO Customer (CustID, CustName) VALUES ($customerId, $customerName);";

    private const string InsertShowingSql = """
        INSERT OR IGNORE INTO Showing (ShowingID, FilmId, ShowingDate, ShowingTime)
        VALUES ($showingId, $filmId, $showingDate, $showingTime);
        """;

    private const string CountUpcomingShowingsSql = """
        SELECT COUNT(1)
        FROM Showing
        WHERE date(ShowingDate) >= date($fromDate);
        """;

    private const string InsertRollingShowingSql = """
        INSERT INTO Showing (FilmId, ShowingDate, ShowingTime)
        VALUES ($filmId, $showingDate, $showingTime);
        """;

    private const string InsertBookingSql = """
        INSERT OR IGNORE INTO Booking (BookingId, ShowingId, CustId, Seats)
        VALUES ($bookingId, $showingId, $customerId, $seats);
        """;

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = await connectionFactory.OpenConnectionAsync(cancellationToken);

        await using (var schemaCommand = connection.CreateCommand())
        {
            schemaCommand.CommandText = SchemaSql;
            await schemaCommand.ExecuteNonQueryAsync(cancellationToken);
        }

        using var transaction = connection.BeginTransaction();
        var today = DateOnly.FromDateTime(timeProvider.GetLocalNow().DateTime);

        await SeedFilmsAsync(connection, transaction, cancellationToken);
        await SeedCustomersAsync(connection, transaction, cancellationToken);
        await SeedShowingsAsync(connection, transaction, today, cancellationToken);
        await EnsureUpcomingShowingsAsync(connection, transaction, today, cancellationToken);
        await SeedBookingsAsync(connection, transaction, cancellationToken);

        transaction.Commit();
        logger.LogInformation("SQLite schema is ready and demo data has been seeded.");
    }

    private static async Task SeedFilmsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        var films = new[]
        {
            (Id: 1L, Title: "The Last Lighthouse"),
            (Id: 2L, Title: "Orbiting Home"),
            (Id: 3L, Title: "A Map of Small Wonders"),
            (Id: 4L, Title: "Midnight at the Arcade")
        };

        foreach (var film in films)
        {
            await using var command = CreateCommand(connection, transaction, InsertFilmSql);
            command.Parameters.AddWithValue("$filmId", film.Id);
            command.Parameters.AddWithValue("$filmTitle", film.Title);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static async Task SeedCustomersAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        var customers = new[]
        {
            (Id: 1L, Name: "Avery Morgan"),
            (Id: 2L, Name: "Jordan Lee"),
            (Id: 3L, Name: "Samira Patel"),
            (Id: 4L, Name: "Diego Santos")
        };

        foreach (var customer in customers)
        {
            await using var command = CreateCommand(connection, transaction, InsertCustomerSql);
            command.Parameters.AddWithValue("$customerId", customer.Id);
            command.Parameters.AddWithValue("$customerName", customer.Name);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static async Task SeedShowingsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        DateOnly today,
        CancellationToken cancellationToken)
    {
        var showings = new[]
        {
            (Id: 1L, FilmId: 1L, Date: today.AddDays(1), Time: new TimeOnly(18, 30)),
            (Id: 2L, FilmId: 2L, Date: today.AddDays(1), Time: new TimeOnly(20, 15)),
            (Id: 3L, FilmId: 3L, Date: today.AddDays(2), Time: new TimeOnly(17, 45)),
            (Id: 4L, FilmId: 1L, Date: today.AddDays(3), Time: new TimeOnly(21, 0)),
            (Id: 5L, FilmId: 4L, Date: today.AddDays(4), Time: new TimeOnly(19, 30))
        };

        foreach (var showing in showings)
        {
            await using var command = CreateCommand(connection, transaction, InsertShowingSql);
            command.Parameters.AddWithValue("$showingId", showing.Id);
            command.Parameters.AddWithValue("$filmId", showing.FilmId);
            command.Parameters.AddWithValue("$showingDate", showing.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            command.Parameters.AddWithValue("$showingTime", showing.Time.ToString("HH:mm:ss", CultureInfo.InvariantCulture));
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static async Task SeedBookingsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        var bookings = new[]
        {
            (Id: 1L, ShowingId: 1L, CustomerId: 1L, Seats: 4L),
            (Id: 2L, ShowingId: 1L, CustomerId: 2L, Seats: 2L),
            (Id: 3L, ShowingId: 2L, CustomerId: 3L, Seats: 5L),
            (Id: 4L, ShowingId: 3L, CustomerId: 4L, Seats: 2L)
        };

        foreach (var booking in bookings)
        {
            await using var command = CreateCommand(connection, transaction, InsertBookingSql);
            command.Parameters.AddWithValue("$bookingId", booking.Id);
            command.Parameters.AddWithValue("$showingId", booking.ShowingId);
            command.Parameters.AddWithValue("$customerId", booking.CustomerId);
            command.Parameters.AddWithValue("$seats", booking.Seats);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static async Task EnsureUpcomingShowingsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        DateOnly today,
        CancellationToken cancellationToken)
    {
        await using (var countCommand = CreateCommand(connection, transaction, CountUpcomingShowingsSql))
        {
            countCommand.Parameters.AddWithValue(
                "$fromDate",
                today.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));

            var count = Convert.ToInt64(
                await countCommand.ExecuteScalarAsync(cancellationToken),
                CultureInfo.InvariantCulture);

            if (count > 0)
            {
                return;
            }
        }

        // Preserve existing operational rows. If the original demo showings have
        // aged out, append a fresh schedule rather than changing showings that
        // may already be referenced by real bookings.
        var showings = new[]
        {
            (FilmId: 1L, Date: today.AddDays(1), Time: new TimeOnly(18, 30)),
            (FilmId: 2L, Date: today.AddDays(1), Time: new TimeOnly(20, 15)),
            (FilmId: 3L, Date: today.AddDays(2), Time: new TimeOnly(17, 45)),
            (FilmId: 1L, Date: today.AddDays(3), Time: new TimeOnly(21, 0)),
            (FilmId: 4L, Date: today.AddDays(4), Time: new TimeOnly(19, 30))
        };

        foreach (var showing in showings)
        {
            await using var command = CreateCommand(connection, transaction, InsertRollingShowingSql);
            command.Parameters.AddWithValue("$filmId", showing.FilmId);
            command.Parameters.AddWithValue(
                "$showingDate",
                showing.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            command.Parameters.AddWithValue(
                "$showingTime",
                showing.Time.ToString("HH:mm:ss", CultureInfo.InvariantCulture));
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    private static SqliteCommand CreateCommand(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string commandText)
    {
        var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = commandText;
        return command;
    }
}
