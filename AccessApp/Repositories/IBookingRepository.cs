using AccessApp.Models;

namespace AccessApp.Repositories;

public interface IBookingRepository
{
    Task<IReadOnlyList<ShowingAvailability>> GetAvailableShowingsAsync(
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<CustomerOption>> GetCustomersAsync(
        CancellationToken cancellationToken = default);

    Task<SeatAvailability?> GetSeatAvailabilityAsync(
        long showingId,
        CancellationToken cancellationToken = default);

    Task<CreateBookingResult> CreateBookingAsync(
        long showingId,
        long customerId,
        int seats,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<BookingSummary>> GetRecentBookingsAsync(
        int take,
        CancellationToken cancellationToken = default);
}
