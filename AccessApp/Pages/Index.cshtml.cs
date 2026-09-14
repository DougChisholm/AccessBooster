using System.ComponentModel.DataAnnotations;
using AccessApp.Models;
using AccessApp.Repositories;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AccessApp.Pages;

public sealed class IndexModel(
    IBookingRepository bookingRepository,
    ILogger<IndexModel> logger) : PageModel
{
    [BindProperty]
    public BookingInput Input { get; set; } = new();

    public IReadOnlyList<ShowingAvailability> Showings { get; private set; } = [];

    public IReadOnlyList<CustomerOption> Customers { get; private set; } = [];

    public IReadOnlyList<BookingSummary> RecentBookings { get; private set; } = [];

    [TempData]
    public string? StatusMessage { get; set; }

    [TempData]
    public string? StatusKind { get; set; }

    public async Task OnGetAsync(long? selectedShowingId, CancellationToken cancellationToken)
    {
        await LoadPageDataAsync(cancellationToken);

        if (selectedShowingId is > 0 && Showings.Any(showing => showing.ShowingId == selectedShowingId))
        {
            Input.ShowingId = selectedShowingId.Value;
        }
    }

    public async Task<IActionResult> OnGetAvailabilityAsync(
        long showingId,
        CancellationToken cancellationToken)
    {
        if (showingId <= 0)
        {
            return BadRequest(new { message = "A valid showing is required." });
        }

        var availability = await bookingRepository.GetSeatAvailabilityAsync(showingId, cancellationToken);
        if (availability is null)
        {
            return NotFound(new { message = "Showing not found or no longer available." });
        }

        return new JsonResult(new
        {
            bookingCount = availability.BookingCount,
            seatsBooked = availability.SeatsBooked,
            seatsLeft = availability.SeatsLeft
        });
    }

    public async Task<IActionResult> OnPostBookAsync(CancellationToken cancellationToken)
    {
        if (!ModelState.IsValid)
        {
            await LoadPageDataAsync(cancellationToken);
            return Page();
        }

        var result = await bookingRepository.CreateBookingAsync(
            Input.ShowingId,
            Input.CustomerId,
            Input.Seats,
            cancellationToken);

        if (!result.Succeeded)
        {
            ModelState.AddModelError(string.Empty, result.Message);
            await LoadPageDataAsync(cancellationToken);
            return Page();
        }

        logger.LogInformation(
            "Booking {BookingId} created for showing {ShowingId}; {SeatsLeft} seats remain.",
            result.BookingId,
            Input.ShowingId,
            result.SeatsLeft);

        StatusMessage = $"Booking #{result.BookingId} accepted. {result.SeatsLeft} seats remain.";
        StatusKind = "success";

        return RedirectToPage(new { selectedShowingId = Input.ShowingId });
    }

    private async Task LoadPageDataAsync(CancellationToken cancellationToken)
    {
        var showingsTask = bookingRepository.GetAvailableShowingsAsync(cancellationToken);
        var customersTask = bookingRepository.GetCustomersAsync(cancellationToken);
        var bookingsTask = bookingRepository.GetRecentBookingsAsync(10, cancellationToken);

        await Task.WhenAll(showingsTask, customersTask, bookingsTask);
        Showings = await showingsTask;
        Customers = await customersTask;
        RecentBookings = await bookingsTask;
    }

    public sealed class BookingInput
    {
        [Range(1, long.MaxValue, ErrorMessage = "Choose an available showing.")]
        [Display(Name = "Showing")]
        public long ShowingId { get; set; }

        [Range(1, long.MaxValue, ErrorMessage = "Choose a customer.")]
        [Display(Name = "Customer")]
        public long CustomerId { get; set; }

        [Range(
            1,
            SqliteBookingRepository.TotalSeatsPerShowing,
            ErrorMessage = "Enter between {1} and {2} seats.")]
        [Display(Name = "Number of seats")]
        public int Seats { get; set; } = 1;
    }
}
