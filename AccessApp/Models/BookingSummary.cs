namespace AccessApp.Models;

public sealed record BookingSummary(
    long BookingId,
    string CustomerName,
    string FilmTitle,
    DateOnly ShowingDate,
    TimeOnly ShowingTime,
    int Seats);
