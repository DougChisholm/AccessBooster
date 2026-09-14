namespace AccessApp.Models;

public sealed record CreateBookingResult(bool Succeeded, long? BookingId, int SeatsLeft, string Message)
{
    public static CreateBookingResult Success(long bookingId, int seatsLeft) =>
        new(true, bookingId, seatsLeft, "Booking accepted.");

    public static CreateBookingResult Failure(string message, int seatsLeft = 0) =>
        new(false, null, seatsLeft, message);
}
