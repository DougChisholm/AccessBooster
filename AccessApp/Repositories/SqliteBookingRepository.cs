using System.Globalization;
using AccessApp.Data;
using AccessApp.Models;
using Microsoft.Data.Sqlite;

namespace AccessApp.Repositories;

/// <summary>
/// Named, stored-procedure-like operations for SQLite. Page handlers never
/// construct SQL, and every value supplied at runtime is bound as a parameter.
/// </summary>
public sealed class SqliteBookingRepository(
    ISqliteConnectionFactory connectionFactory,
    TimeProvider timeProvider) : IBookingRepository
{
    public const int TotalSeatsPerShowing = 50;

    private const string FilmsAvailableProcedure = """
        SELECT
            s.ShowingID,
            f.FilmTitle,
            s.ShowingDate,
            s.ShowingTime,
            COUNT(b.BookingId) AS BookingCount,
            COALESCE(SUM(b.Seats), 0) AS SeatsBooked,
            $totalSeats - COALESCE(SUM(b.Seats), 0) AS SeatsLeft
        FROM Showing AS s
        INNER JOIN Film AS f ON f.FilmId = s.FilmId
        LEFT JOIN Booking AS b ON b.ShowingId = s.ShowingID
        WHERE date(s.ShowingDate) >= date($fromDate)
        GROUP BY s.ShowingID, f.FilmTitle, s.ShowingDate, s.ShowingTime
        ORDER BY f.FilmTitle, s.ShowingDate, s.ShowingTime;
        """;

    private const string GetCustomersProcedure = """
        SELECT CustID, CustName
        FROM Customer
        ORDER BY CustName;
        """;

    private const string GetSeatAvailabilityProcedure = """
        SELECT
            COUNT(b.BookingId) AS BookingCount,
            COALESCE(SUM(b.Seats), 0) AS SeatsBooked,
            $totalSeats - COALESCE(SUM(b.Seats), 0) AS SeatsLeft
        FROM Showing AS s
        LEFT JOIN Booking AS b ON b.ShowingId = s.ShowingID
        WHERE s.ShowingID = $showingId
          AND date(s.ShowingDate) >= date($fromDate)
        GROUP BY s.ShowingID;
        """;

    private const string ValidateShowingProcedure = """
        SELECT COUNT(1)
        FROM Showing
        WHERE ShowingID = $showingId
          AND date(ShowingDate) >= date($fromDate);
        """;

    private const string ValidateCustomerProcedure = """
        SELECT COUNT(1)
        FROM Customer
        WHERE CustID = $customerId;
        """;

    private const string GetBookedSeatsProcedure = """
        SELECT COALESCE(SUM(Seats), 0)
        FROM Booking
        WHERE ShowingId = $showingId;
        """;

    private const string CreateBookingProcedure = """
        INSERT INTO Booking (ShowingId, CustId, Seats)
        VALUES ($showingId, $customerId, $seats);
        SELECT last_insert_rowid();
        """;

    private const string GetRecentBookingsProcedure = """
        SELECT
            b.BookingId,
            c.CustName,
            f.FilmTitle,
            s.ShowingDate,
            s.ShowingTime,
            b.Seats
        FROM Booking AS b
        INNER JOIN Customer AS c ON c.CustID = b.CustId
        INNER JOIN Showing AS s ON s.ShowingID = b.ShowingId
        INNER JOIN Film AS f ON f.FilmId = s.FilmId
        ORDER BY b.BookingId DESC
        LIMIT $take;
        """;

    public async Task<IReadOnlyList<ShowingAvailability>> GetAvailableShowingsAsync(
        CancellationToken cancellationToken = default)
    {
        var results = new List<ShowingAvailability>();
        await using var connection = await connectionFactory.OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = FilmsAvailableProcedure;
        command.Parameters.AddWithValue("$totalSeats", TotalSeatsPerShowing);
        command.Parameters.AddWithValue("$fromDate", TodayText());

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            results.Add(new ShowingAvailability(
                reader.GetInt64(0),
                reader.GetString(1),
                ParseDate(reader.GetString(2)),
                ParseTime(reader.GetString(3)),
                reader.GetInt32(4),
                reader.GetInt32(5),
                Math.Max(0, reader.GetInt32(6))));
        }

        return results;
    }

    public async Task<IReadOnlyList<CustomerOption>> GetCustomersAsync(
        CancellationToken cancellationToken = default)
    {
        var results = new List<CustomerOption>();
        await using var connection = await connectionFactory.OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = GetCustomersProcedure;

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            results.Add(new CustomerOption(reader.GetInt64(0), reader.GetString(1)));
        }

        return results;
    }

    public async Task<SeatAvailability?> GetSeatAvailabilityAsync(
        long showingId,
        CancellationToken cancellationToken = default)
    {
        await using var connection = await connectionFactory.OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = GetSeatAvailabilityProcedure;
        command.Parameters.AddWithValue("$showingId", showingId);
        command.Parameters.AddWithValue("$totalSeats", TotalSeatsPerShowing);
        command.Parameters.AddWithValue("$fromDate", TodayText());

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        return new SeatAvailability(
            reader.GetInt32(0),
            reader.GetInt32(1),
            Math.Max(0, reader.GetInt32(2)));
    }

    public async Task<CreateBookingResult> CreateBookingAsync(
        long showingId,
        long customerId,
        int seats,
        CancellationToken cancellationToken = default)
    {
        if (showingId <= 0 || customerId <= 0)
        {
            return CreateBookingResult.Failure("Select a showing and customer.");
        }

        if (seats is < 1 or > TotalSeatsPerShowing)
        {
            return CreateBookingResult.Failure($"Seats must be between 1 and {TotalSeatsPerShowing}.");
        }

        await using var connection = await connectionFactory.OpenConnectionAsync(cancellationToken);
        // IMMEDIATE obtains the write lock before checking capacity, preventing
        // two concurrent requests from both booking the same remaining seats.
        using var transaction = connection.BeginTransaction(deferred: false);

        if (!await ExistsAsync(
                connection,
                transaction,
                ValidateShowingProcedure,
                ("$showingId", showingId),
                ("$fromDate", TodayText()),
                cancellationToken))
        {
            return CreateBookingResult.Failure("The selected showing is no longer available.");
        }

        if (!await ExistsAsync(
                connection,
                transaction,
                ValidateCustomerProcedure,
                ("$customerId", customerId),
                cancellationToken))
        {
            return CreateBookingResult.Failure("The selected customer does not exist.");
        }

        var seatsBooked = await GetBookedSeatsAsync(connection, transaction, showingId, cancellationToken);
        var seatsLeft = Math.Max(0, TotalSeatsPerShowing - seatsBooked);

        if (seats > seatsLeft)
        {
            var noun = seatsLeft == 1 ? "seat" : "seats";
            var verb = seatsLeft == 1 ? "is" : "are";
            return CreateBookingResult.Failure(
                seatsLeft == 0
                    ? "Sorry, this showing is full."
                    : $"Sorry, only {seatsLeft} {noun} {verb} available.",
                seatsLeft);
        }

        await using var command = CreateCommand(connection, transaction, CreateBookingProcedure);
        command.Parameters.AddWithValue("$showingId", showingId);
        command.Parameters.AddWithValue("$customerId", customerId);
        command.Parameters.AddWithValue("$seats", seats);

        var value = await command.ExecuteScalarAsync(cancellationToken);
        var bookingId = Convert.ToInt64(value, CultureInfo.InvariantCulture);
        transaction.Commit();

        return CreateBookingResult.Success(bookingId, seatsLeft - seats);
    }

    public async Task<IReadOnlyList<BookingSummary>> GetRecentBookingsAsync(
        int take,
        CancellationToken cancellationToken = default)
    {
        var results = new List<BookingSummary>();
        await using var connection = await connectionFactory.OpenConnectionAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = GetRecentBookingsProcedure;
        command.Parameters.AddWithValue("$take", Math.Clamp(take, 1, 100));

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            results.Add(new BookingSummary(
                reader.GetInt64(0),
                reader.GetString(1),
                reader.GetString(2),
                ParseDate(reader.GetString(3)),
                ParseTime(reader.GetString(4)),
                reader.GetInt32(5)));
        }

        return results;
    }

    private async Task<int> GetBookedSeatsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        long showingId,
        CancellationToken cancellationToken)
    {
        await using var command = CreateCommand(connection, transaction, GetBookedSeatsProcedure);
        command.Parameters.AddWithValue("$showingId", showingId);
        var value = await command.ExecuteScalarAsync(cancellationToken);
        return Convert.ToInt32(value, CultureInfo.InvariantCulture);
    }

    private static async Task<bool> ExistsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string procedure,
        (string Name, object Value) parameter,
        CancellationToken cancellationToken)
    {
        return await ExistsAsync(connection, transaction, procedure, [parameter], cancellationToken);
    }

    private static async Task<bool> ExistsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string procedure,
        (string Name, object Value) firstParameter,
        (string Name, object Value) secondParameter,
        CancellationToken cancellationToken)
    {
        return await ExistsAsync(
            connection,
            transaction,
            procedure,
            [firstParameter, secondParameter],
            cancellationToken);
    }

    private static async Task<bool> ExistsAsync(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string procedure,
        IReadOnlyList<(string Name, object Value)> parameters,
        CancellationToken cancellationToken)
    {
        await using var command = CreateCommand(connection, transaction, procedure);
        foreach (var parameter in parameters)
        {
            command.Parameters.AddWithValue(parameter.Name, parameter.Value);
        }

        var value = await command.ExecuteScalarAsync(cancellationToken);
        return Convert.ToInt64(value, CultureInfo.InvariantCulture) > 0;
    }

    private static SqliteCommand CreateCommand(
        SqliteConnection connection,
        SqliteTransaction transaction,
        string procedure)
    {
        var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = procedure;
        return command;
    }

    private string TodayText() =>
        DateOnly.FromDateTime(timeProvider.GetLocalNow().DateTime)
            .ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static DateOnly ParseDate(string value) =>
        DateOnly.ParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static TimeOnly ParseTime(string value) =>
        TimeOnly.ParseExact(value, "HH:mm:ss", CultureInfo.InvariantCulture);
}
