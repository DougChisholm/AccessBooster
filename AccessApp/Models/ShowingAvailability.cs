namespace AccessApp.Models;

public sealed record ShowingAvailability(
    long ShowingId,
    string FilmTitle,
    DateOnly ShowingDate,
    TimeOnly ShowingTime,
    int BookingCount,
    int SeatsBooked,
    int SeatsLeft);
