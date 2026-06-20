# Rent Me CT Wheelbase Integration Notes

## What We Changed Now

### Direct vehicle links

Each confirmed car in `cars.html` was connected to its specific Wheelbase listing using the correct `rental_id`.

When a customer clicks **Reserve This Car**, the page now builds a Wheelbase URL with:

- `dealer_id=4960447`
- `store_type=auto`
- `page=listing-details`
- the selected vehicle's `rental_id`
- pickup date
- return date
- pickup time
- return time
- Wheelbase router state through `wb_state`

The goal is that clicking a car, like **Buick Encore #649**, sends the customer directly to that exact Buick listing instead of the general Wheelbase car list.

### Date and time preservation

The reservation link now carries the selected rental period from `cars.html`.

Dates are sent as:

- `from`
- `to`
- `wb-from`
- `wb-to`

Times are converted from labels like `9:00 AM` into Wheelbase-style seconds after midnight:

- `from_time`
- `to_time`
- `wb-from-time`
- `wb-to-time`

Example:

```text
9:00 AM = 32400
```

The original readable pickup/return times are also kept in the URL and local storage as fallback data.

### Wheelbase rental IDs matched

We fetched the live Wheelbase auto fleet and matched the current cars to Wheelbase rental IDs.

Confirmed examples:

- Buick Encore #649: `524203`
- Ford Escape #650: `524202`
- Kia Soul #656: `524201`
- Audi A6 #473: `517449`
- Audi A4 #158: `517446`
- Audi A8L #YPS: `517442`
- Ford F350 #191: `517467`
- Benz C300 #418: `517460`
- Benz CLS #224: `517457`
- Dodge Van #452: `517466`
- Audi Q5 #149: `517450`
- Audi Q5 #225: `517452`
- Dodge Van #451: `517465`
- BMW 330I #157: `517462`
- Cadillac ATS #780: `517464`
- Mercedes C300 #321: `517458`
- Audi A4 #002: `517445`
- Audi A6 #385: `517448`
- Audi S3 #001: `517443`
- Audi Q5 #474: `517447`
- Audi Q5 #234: `517453`
- Audi Q5 #203: `517451`
- Mercedes Benz C300 #677: `517459`
- BMW 328I #004: `517461`
- BMW 330XI #166: `517463`
- Audi Q5 #210: `517444`
- Audi Q3 #100: `517456`
- Audi Q5 #997: `517454`

### One unmatched car

`Audi Q5 #148` is still on the old local selection flow because it was not present in the live Wheelbase auto rental response when checked.

Before connecting that card directly, we need the correct Wheelbase `rental_id`.

### Availability sync disabled on purpose

The hidden Wheelbase availability bridge was disabled for now.

Reason:

It was causing all cars to show as unavailable and blocking the customer flow.

Current behavior:

- Cars remain clickable.
- Direct Wheelbase listing links stay active.
- The availability label does not rely on live Wheelbase status.

This is intentional for now.

## What We Should Do Later For Availability Sync

### Goal

Reconnect live Wheelbase availability without breaking the customer booking flow.

The availability system should:

- Check the selected pickup and return dates.
- Check the selected vehicle's actual Wheelbase `rental_id`.
- Show available/unavailable accurately.
- Never mark all cars unavailable because of a failed widget load.
- Never disable every reservation button from one bad API response.

### Safer future approach

Instead of using the hidden Wheelbase widget bridge, use the Wheelbase/Outdoorsy API directly.

Use each card's `data-wheelbase-rental-id`.

For each vehicle, check availability with:

```text
https://api.outdoorsy.com/v0/availability?rental_id=RENTAL_ID&from=YYYY-MM-DD&to=YYYY-MM-DD
```

If Wheelbase requires time-level checking, include:

```text
from_time=SECONDS
to_time=SECONDS
```

### Availability UI rules

When dates are not selected:

- Label: `Select dates first`
- Button: enabled, but click prompts user to select dates.

When dates are selected and API says available:

- Label: `Available`
- Button: enabled.

When dates are selected and API says unavailable:

- Label: `Unavailable`
- Button can be disabled, or stay enabled with a warning depending on business preference.

When API fails:

- Label: `Check in checkout`
- Button stays enabled.

This prevents one API problem from killing all reservations.

### Implementation checklist for later

1. Remove the disabled hidden Wheelbase widget bridge code or leave it unused.
2. Add a new function like `checkVehicleAvailability(card)`.
3. Read `data-wheelbase-rental-id` from each card.
4. Read pickup date, return date, pickup time, and return time.
5. Convert times to seconds using the existing `getWheelbaseTimeInSeconds()` helper.
6. Fetch the availability endpoint per car.
7. Update only that one card's label and button state.
8. Add error fallback so failed API checks do not disable the car.
9. Debounce date/time changes so changing a date does not spam the API.
10. Test with several vehicles and date ranges before enabling on the live site.

### Important rule

Do not reconnect live availability until direct vehicle routing is confirmed working for the customer flow.

The priority order is:

1. Customer chooses dates and times.
2. Customer clicks a specific car.
3. Customer lands on that exact Wheelbase car listing.
4. Dates/times are preserved as much as Wheelbase supports.
5. Availability sync can be added after that flow is stable.

## Current Status

Direct Wheelbase links are wired for confirmed cars.

Live availability syncing is intentionally disabled for now.

Later, availability should be rebuilt using a safer direct API approach with fallback behavior.
