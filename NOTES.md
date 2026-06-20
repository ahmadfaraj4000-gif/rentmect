# Rent Me CT Notes

## Fleet Mileage Workflow

- At vehicle pickup, the admin must enter the starting mileage before marking the rental active.
- At vehicle return, the admin must enter the ending mileage before completing the rental.
- The app stores pickup mileage, return mileage, calculated miles driven, and updates the vehicle current mileage.

## Toll Billing

- Planned toll integration provider: Bestpass Developer API.
- Developer docs: https://developer.bestpass.com/
- Use Bestpass toll usage data to match toll transactions to rentals by vehicle/date/time and add billable tolls to the customer invoice.
