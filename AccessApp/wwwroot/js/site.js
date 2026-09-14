(() => {
    "use strict";

    const form = document.getElementById("booking-form");
    if (!form) {
        return;
    }

    const radioButtons = Array.from(form.querySelectorAll('input[name="Input.ShowingId"]'));
    const bookingCount = document.getElementById("booking-count");
    const seatCount = document.getElementById("seat-count");
    const seatsLeft = document.getElementById("seats-left");
    const caption = document.getElementById("availability-caption");
    const submitButton = document.getElementById("make-booking");
    let requestNumber = 0;

    const updateValues = (radio) => {
        const row = radio.closest(".showing-row");
        bookingCount.textContent = radio.dataset.bookings ?? "—";
        seatCount.textContent = radio.dataset.booked ?? "—";
        seatsLeft.textContent = radio.dataset.left ?? "—";
        caption.textContent = row?.querySelector(".showing-main strong")?.textContent ?? "Selected showing";
        submitButton.disabled = Number(radio.dataset.left ?? 0) <= 0;
    };

    const refreshAvailability = async (radio) => {
        const thisRequest = ++requestNumber;

        try {
            const response = await fetch(`/?handler=Availability&showingId=${encodeURIComponent(radio.value)}`, {
                headers: { "Accept": "application/json" }
            });

            if (!response.ok || thisRequest !== requestNumber) {
                return;
            }

            const data = await response.json();
            radio.dataset.bookings = data.bookingCount;
            radio.dataset.booked = data.seatsBooked;
            radio.dataset.left = data.seatsLeft;
            updateValues(radio);

            const badge = radio.closest(".showing-row")?.querySelector(".seat-badge");
            if (badge) {
                badge.textContent = data.seatsLeft > 0 ? `${data.seatsLeft} left` : "Full";
                badge.classList.toggle("seat-badge-full", data.seatsLeft <= 0);
            }
        } catch {
            // The server validates availability again during POST, so a failed
            // optional refresh does not make the booking workflow unsafe.
        }
    };

    radioButtons.forEach((radio) => {
        radio.addEventListener("change", () => {
            updateValues(radio);
            refreshAvailability(radio);
        });
    });

    const selected = radioButtons.find((radio) => radio.checked);
    if (selected) {
        updateValues(selected);
    }
})();
