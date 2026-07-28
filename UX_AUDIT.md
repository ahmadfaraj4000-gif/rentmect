# Rent Me CT UX Audit

Audit date: July 25, 2026  
Scope: public marketing/fleet site, client portal, admin portal  
Method: source-backed UX, interaction, visual-hierarchy, responsive, and accessibility audit. No product code was changed.

## 1. Executive summary

The application has three user-facing surfaces:

1. A static public site (`index.html`, `cars.html`, `script.js`, `styles.css`) that currently sends the primary booking journey to Wheelbase.
2. A React/Vite client portal (`rentmect-client-portal`) with passwordless authentication, a guided booking flow, document upload, Stripe Identity, agreement signing, billing, return, extension, and messaging.
3. A React/Vite admin portal (`rentmect-admin-portal`) with dashboard, operations queue, payment ledger, canonical fleet calendar, bookings, rentals, customers, communications, vehicles/maintenance, audit log, and settings.

Both React portals are single-file applications centered on very large `main.jsx` files. Navigation is held in component state rather than a router. Shared interface primitives exist, but most are defined inline and are not used consistently. The public site also has a shared script, but page-specific inline scripts redefine global functions and create a second layer of behavior.

The strongest parts are the guided client checklist, explicit checkout hold timer, maintenance-aware calendar, manual-booking summary, return mileage enforcement, customer-contact preview, and the recent consolidation of Payments and Settings. Those patterns show the right product instincts: keep critical state visible, constrain risky actions, and explain what happens next.

The principal launch risks are:

- Both portals can turn failed data requests into believable empty screens.
- The admin dashboard can crash when an emergency exception is present because `Dashboard` reads `rentals` without receiving it.
- Public fleet cards treat unknown availability as bookable and even include unknown cards in “Available only.”
- A hard-coded test vehicle is fetched and forcibly marked available in the customer bundle without an environment guard.
- The public site and client portal expose competing booking architectures, so the visible promise, availability source, checkout, and post-booking experience are not one continuous journey.

After those blockers, the largest UX cost comes from fragmented feedback and design foundations: global auto-expiring notices, raw infrastructure errors, missing per-action busy states, inaccessible modal behavior, mouse-only calendar painting, faux tables, unlabeled controls, and extensive CSS override layers. These issues make the system harder for clients to trust and harder for admins to operate quickly under pressure.

### Architecture and interaction map

| Surface | Framework/routing | Shared UI | Primary flows | Main risk |
|---|---|---|---|---|
| Public site | Static multi-page HTML; global and inline JavaScript | `styles.css`, `script.js`, repeated page markup | Date selection, fleet filtering, availability, insurance reminder, Wheelbase handoff, promotions, contact, chatbot | Duplicate globals and a booking path that diverges from the client portal |
| Client portal | React + Vite; query parameters plus `activeTab` state, no route library | Inline `Notice`, `Panel`, `Metric`, `WizardModal`, `UploadCard`, preview components | Passwordless login, profile/phone, vehicle, identity, uploads, agreement, Stripe, return/extension, messages | Silent load failures and three overlapping checkout presentations |
| Admin portal | React + Vite; `activeTab` state, no route library | Inline `Panel`, `Metric`, badges, rows, modals; several CSS layers | Dashboard, queue, payments, calendar, manual booking, rental operations, customers, communications, maintenance, settings | Dense operational UI, silent partial data, and inconsistent mutation feedback |

## 2. Critical issues

The following issues should block a confident launch until they are resolved and verified.

| Severity | Concept | Page/Component | File | Problem | Recommended Fix | Effort |
|---|---|---|---|---|---|---|
| Critical | Error prevention; visibility of system status | Admin Dashboard — `Dashboard` | `rentmect-admin-portal/src/main.jsx:2366` | `Dashboard` calls `rentals.find(...)` when rendering emergency exceptions, but `rentals` is neither a prop nor a local variable. The page can throw and disappear precisely when an exception needs attention. | Pass the relevant rental data into `Dashboard`, add an error boundary around route content, and test with at least one active/expired exception. Recovery copy: “The dashboard could not display exception details. Rental operations are still available.” | S |
| Critical | Visibility of system status; error recovery | Admin bootstrap — `loadAllData` | `rentmect-admin-portal/src/main.jsx:615` | Twenty-two requests run together, but errors are ignored for every domain except Payments. A failed vehicles, rentals, documents, or maintenance request becomes an apparently valid empty section. Admins can make unsafe decisions from incomplete data. | Track each domain as `loading / ready / error / stale`, show a persistent degraded-data banner, preserve last successful data, and provide “Retry failed data.” Copy: “Rentals could not refresh. Showing data from 10:42 PM.” | M |
| Critical | Visibility of system status; trust | Client bootstrap — `loadPortalData` | `rentmect-client-portal/src/main.jsx:1026` | All result errors are ignored and `portalDataReady` is set true. A customer may see no rental, no documents, no messages, or no charges and reasonably conclude the records do not exist. | Treat required resources as blocking and optional resources as degraded. Never render “no rental” or “no documents” until that resource successfully resolves. Copy: “We could not load your booking records. Nothing has been changed. Try again.” | M |
| Critical | Error prevention; match with real world | Public fleet availability — `markCardNeedsWheelbaseCheckout`, `applyCustomFleetFilter` | `cars.html:1402`, `cars.html:1838` | Cards in `unknown` or `checking` state keep an enabled “Book This Car” button, and “Available cars only” includes pending cards. The UI presents uncertainty as availability and pushes failure later into checkout. | Unknown must not equal bookable. Disable the booking action until the canonical check succeeds; keep pending cards visible only outside “Available only.” Copy: “Checking availability…” then either “Available for your dates” or a specific unavailable reason. | S |
| Critical | Error prevention; production safety | Client preview fleet — `BookingPreviewFleet` | `rentmect-client-portal/src/BookingPreviewFleet.jsx:7`, `rentmect-client-portal/src/BookingPreviewFleet.jsx:83`, `rentmect-client-portal/src/BookingPreviewFleet.jsx:124` | The production bundle fetches a fixed test vehicle even when unpublished and forcibly marks it available regardless of inventory. Anyone who reaches `?preview=fleet` can see and book the test lane. | Compile test behavior only under an explicit non-production flag, require authorized QA access, and remove forced availability from production builds. Copy for authorized QA: “Sandbox vehicle — no real reservation will be created.” | M |

## 3. High-priority issues

| Severity | Concept | Page/Component | File | Problem | Recommended Fix | Effort |
|---|---|---|---|---|---|---|
| High | Consistency; information architecture | Public-to-client booking handoff — `goToWheelbaseCheckout`, `openBookingPreview` | `cars.html:2066`, `cars.html:2080`; `index.html:291` | The visible site promises Wheelbase checkout and the main fleet routes there, while the Supabase-backed client fleet is exposed as a footer “Booking Preview.” Customers encounter two availability sources, two checkout designs, and different language. | Choose one production funnel and make all “Reserve,” “Choose Vehicle,” cards, and follow-up links enter it. Keep the other behind an explicit staff-only preview. | L |
| High | User control; information architecture | Portal navigation — `App`, `selectAdminTab`, client `setActiveTab` | `rentmect-admin-portal/src/main.jsx:280`, `rentmect-admin-portal/src/main.jsx:2328`; `rentmect-client-portal/src/main.jsx:352`, `rentmect-client-portal/src/main.jsx:2462` | Portal pages are state branches, not URL routes. Refresh resets context, browser Back does not undo navigation, admins cannot share a rental/payment view, and support cannot link clients to the exact step. | Add route-backed navigation with stable URLs and preserved filter/detail state. Example: `/rentals/:id`, `/payments?view=attention`, `/booking/documents`. | L |
| High | Visibility of system status; accessibility | Global feedback — `notify`, `Notice` | `rentmect-admin-portal/src/main.jsx:416`, `rentmect-admin-portal/src/main.jsx:5479`; `rentmect-client-portal/src/main.jsx:412`, `rentmect-client-portal/src/main.jsx:3792` | One notice replaces another, disappears after 5.2 seconds, has no `role=status/alert` or `aria-live`, and is detached from the control that caused it. Multi-step actions can overwrite warnings with success. Screen-reader users may receive no announcement. | Use a queued toast region for transient success, persistent inline errors for failures, and field-level feedback for validation. Copy: “Insurance uploaded. Review usually takes one business hour.” | M |
| High | Keyboard access; focus management | Client guided flow — `WizardModal`, `AgreementModal` | `rentmect-client-portal/src/main.jsx:3094`, `rentmect-client-portal/src/main.jsx:3607` | The two principal checkout modals lack dialog roles, accessible names, Escape behavior, initial focus, focus trapping, focus restoration, and background inertness. The wizard close button also has no accessible label. | Build one accessible modal primitive and migrate both. Keep focus inside, close with Escape when safe, restore focus to the opener, and use `aria-labelledby`/`aria-describedby`. | M |
| High | Keyboard access; focus management | Admin modals — `AvailabilityBlockModal`, customer details, emergency/cancel/override dialogs | `rentmect-admin-portal/src/main.jsx:2892`, `rentmect-admin-portal/src/main.jsx:3071`, `rentmect-admin-portal/src/main.jsx:4909` | Several dialogs have role metadata, but there is no shared focus trap/restoration; Escape and backdrop behavior vary by modal. A keyboard user can tab into the page behind a destructive dialog. | Consolidate on one admin modal primitive with consistent dismissal rules and focus lifecycle. Destructive modals should not close on accidental backdrop clicks. | M |
| High | Visibility of system status; error prevention | Client uploads — `uploadDocument`, `replaceDocument`, `UploadCard` | `rentmect-client-portal/src/main.jsx:1461`, `rentmect-client-portal/src/main.jsx:1563`, `rentmect-client-portal/src/main.jsx:4356` | Upload controls have no per-file busy state, progress, file-size/type validation copy, cancel/retry, or duplicate-click protection. “Start” does not communicate that it opens a file picker. | Add per-document upload state and validation before transfer. Disable replacement while saving. Copy: “Uploading insurance… 62%” and “PDF, JPG, or PNG up to 10 MB.” Rename action to “Choose file.” | M |
| High | Error prevention; feedback | Admin row actions — `updateVehicleStatus`, `updateVehiclePublished`, queue/document/payment handlers | `rentmect-admin-portal/src/main.jsx:1208`, `rentmect-admin-portal/src/main.jsx:1220`, `rentmect-admin-portal/src/main.jsx:2395`, `rentmect-admin-portal/src/main.jsx:3582` | Many mutations have no row-specific busy state. Status selects, publish controls, approvals, rejections, waivers, and reminders can be activated repeatedly before the response returns. | Maintain operation state by record and action, disable only the affected control, show an inline spinner/status, and make server operations idempotent. Copy: “Publishing…” / “Published.” | M |
| High | Error prevention; consistency | Destructive actions — refund/delete/extension confirmations | `rentmect-admin-portal/src/main.jsx:1047`, `rentmect-admin-portal/src/main.jsx:1078`, `rentmect-admin-portal/src/main.jsx:1412`, `rentmect-admin-portal/src/main.jsx:1468` | High-stakes actions mix native `window.confirm`, custom cancel modals, and immediate buttons. The amount, customer, downstream effect, and recovery path are not presented consistently. | Use one confirmation pattern with object, amount, consequence, and reversible alternative. Copy: “Refund $300 to Jane Smith? Stripe refunds cannot be undone here.” | M |
| High | Help users recover from errors | Client/admin request errors | `rentmect-admin-portal/src/main.jsx` (for example `:801`, `:844`, `:913`); `rentmect-client-portal/src/main.jsx` (for example `:1197`, `:1396`, `:1592`) | Raw Supabase, Edge Function, Stripe, schema-cache, and RLS messages are frequently shown directly. One client message tells the renter to “Run the rental_documents table RLS policies.” This is unactionable and exposes implementation vocabulary. | Map known failures to plain-language recovery messages, log the technical detail with a correlation ID, and offer Retry/Contact Support. Copy: “We could not save the document record. Your file is safe; contact us with code DOC-104.” | M |
| High | Labels; error identification | Placeholder-only controls | `rentmect-client-portal/src/main.jsx:2750`, `rentmect-client-portal/src/main.jsx:3200`, `rentmect-client-portal/src/main.jsx:4257`; `rentmect-admin-portal/src/main.jsx:3556`, `rentmect-admin-portal/src/main.jsx:3868`, `rentmect-admin-portal/src/main.jsx:4611`, `rentmect-admin-portal/src/main.jsx:5440` | Important email, password, name, phone, code, vehicle-edit, template, discount, and fee controls use placeholders without persistent labels. Placeholders disappear after entry and are not a dependable accessible name. | Require visible labels and programmatic associations for every field. Use placeholders only as examples. Put validation under the relevant field and focus the first invalid field on submit. | M |
| High | Keyboard access; equivalent interaction | Admin Fleet Calendar — `FleetCalendar` | `rentmect-admin-portal/src/main.jsx:2502`, especially `:2794` | Creating a block by dragging empty date cells is mouse-only. Empty cells are non-focusable `div`s; keyboard/touch users cannot perform the same direct manipulation. Tooltips also carry information that is difficult to access on touch. | Keep the form as the complete keyboard path, make each cell/segment focusable with a visible label, and provide “Block this day” / “Edit segment” actions. Announce selected ranges. | L |
| High | Semantics; scanability | Payments and operational lists — `PaymentsTab`, `OperationsQueue`, `AuditLog` | `rentmect-admin-portal/src/main.jsx:2395`, `rentmect-admin-portal/src/main.jsx:2438`, `rentmect-admin-portal/src/main.jsx:3230` | Tabular data is rendered as grids of `div`s without table semantics or explicit row/column associations. Visual users can scan columns; screen-reader users cannot reliably relate amount, status, and date to the right customer. | Use semantic tables for true tables and descriptive lists/articles for cards. Add sortable headers only when sorting exists. Keep a mobile card representation with explicit field labels. | L |
| High | Consistency; design-system integrity | Portal styling cascade | `rentmect-admin-portal/src/styles.css`, `rentmect-admin-portal/src/final-overrides.css`; `rentmect-client-portal/src/styles.css`, `rentmect-client-portal/src/final-overrides.css` | Admin CSS declares `:root` eleven times across its two main files and the client declares it nine times. Core selectors are repeatedly overridden with hundreds of `!important` declarations. The same token names change from red/green to black across the cascade. Visual behavior depends on import order rather than a stable system. | Consolidate tokens into one foundation, component styles into one ownership layer, and page exceptions into scoped modules. Remove obsolete theme passes after visual regression testing. | L |
| High | Cognitive load; progressive disclosure | Admin rental operations — `RentalRow` | `rentmect-admin-portal/src/main.jsx:4714` | One row owns progress, documents, procedure controls, payments, charges, deposit, extensions, messages, reminders, cancellation, return, damage, and emergency overrides. Too many actions compete at one level, increasing scan time and misclick risk. | Make the row a compact summary with one recommended next action; open a route-backed rental workspace with sections for Checklist, Money, Customer, Vehicle, and History. Keep exceptions in a clearly separated danger zone. | L |
| High | Efficient task completion | Operations Queue and Payments — `OperationsQueue`, `PaymentsTab` | `rentmect-admin-portal/src/main.jsx:2395`, `rentmect-admin-portal/src/main.jsx:2438` | Queue buckets cap display at five and tell admins to go elsewhere; payment “Needs Attention” rows have no action or rental link. The system identifies work but does not carry the admin to the resolution context. | Make each row open the exact rental/document/payment task. Add “View all 12” per bucket and one contextual primary action. Preserve the originating filter on Back. | M |
| High | Accessibility; user control | Public navigation and modals — `toggleMenu`, contact/promotion/insurance dialogs | `script.js:389`, `script.js:486`, `script.js:491`; `cars.html:2140` | Mobile menu buttons lack `aria-expanded`/`aria-controls`. Contact and insurance dialogs do not move, trap, or restore focus; insurance has no Escape handler. Promotion moves focus but does not trap or restore it. | Add a reusable menu toggle and dialog controller with full keyboard behavior. Return focus to the initiating vehicle card after the insurance modal closes. | M |
| High | Consistency; maintainability | Client checkout presentations — `WizardModal`, `PreviewCheckout`, signed-in portal sections | `rentmect-client-portal/src/main.jsx:3094`, `rentmect-client-portal/src/main.jsx:4026`, `rentmect-client-portal/src/main.jsx:2506` | Contact, vehicle, identity, uploads, agreement, and payment are rendered in three different presentations with repeated fields and action wiring. Copy, validation, accessibility, and loading behavior can drift even when the business flow is the same. | Define one step model and reusable step components; render them in guest, guided, and account shells without duplicating behavior. | L |
| High | Visibility of system status; appropriate disclosure | Admin authentication — `checkAdminRole`, `NotAdmin` | `rentmect-admin-portal/src/main.jsx:438`, `rentmect-admin-portal/src/main.jsx:5459` | After session load, `isAdminUser` is initially false, so “Not Authorized” can flash while the role query is still running. The denial screen then exposes a Supabase SQL grant recipe containing the signed-in email. | Add an explicit `roleChecking` state. Show a neutral verification screen, then a normal access-denied message with support contact; keep database remediation out of the production UI. | S |

## 4. Medium-priority improvements

| Severity | Concept | Page/Component | File | Problem | Recommended Fix | Effort |
|---|---|---|---|---|---|---|
| Medium | Empty-state guidance | Admin/client lists and history | `rentmect-admin-portal/src/main.jsx:2395`, `:2933`, `:3230`, `:4163`; `rentmect-client-portal/src/main.jsx:2827`, `:2955`, `:2972` | Most empty states are one muted sentence with no explanation of whether data loaded, no next action, and no reset path for filters. | Use three distinct states: first-use, no filter results, and load failure. Add actions such as “Clear filters,” “Create booking,” or “Message support.” | M |
| Medium | Perceived performance | App loading and manual refresh — `Loading`, `LoadingScreen`, header `Refresh` | `rentmect-admin-portal/src/main.jsx:5439`, `:2345`; `rentmect-client-portal/src/main.jsx:3783` | Both portals replace the whole application with an animated loading screen. Admin Refresh triggers the same full-screen state and has no button-level busy feedback. | Use shell-preserving skeletons on first load and stale-while-refreshing updates afterward. Change Refresh to “Refreshing…” with last-updated time. | M |
| Medium | State semantics | Filter pills and settings tabs | `rentmect-admin-portal/src/main.jsx:2452`, `:2940`, `:4472`; `rentmect-client-portal/src/main.jsx:2462` | Active filters are conveyed through class styling only. Settings declares a `tablist`, but buttons lack `role=tab`, `aria-selected`, controls, and tab panels. Portal navigation does not expose `aria-current`. | Use `aria-pressed` for filters, complete the tabs pattern for Settings, and add `aria-current="page"` to route navigation. | S |
| Medium | Status communication | Admin `RentalProgressTracker`; client wizard progress | `rentmect-admin-portal/src/main.jsx:5391`; `rentmect-client-portal/src/main.jsx:3148` | Progress is visually rich but status/detail is mainly in CSS classes and `title` tooltips. Wizard dots are non-interactive and unnamed to assistive technology. | Render an ordered list with current/completed/pending text, `aria-current="step"`, and visible details for blocked steps. | M |
| Medium | Error recovery; data freshness | Admin calendar — `loadCanonicalCalendar` | `rentmect-admin-portal/src/main.jsx:2547` | A refresh error inserts raw error text into a general hint while prior events can remain visible. There is no “last updated,” explicit stale state, or retry action, so admins may trust old availability. | Separate stale-data error from interaction hints, timestamp successful refreshes, dim/mark stale data, and provide Retry. Copy: “Calendar is showing data from 10:39 PM. Live refresh failed.” | M |
| Medium | Hick’s Law; grouping | Public fleet filters | `cars.html:399`–`cars.html:415` | “Available only,” nine brand buttons, and five vehicle-type buttons share one undifferentiated control region. On smaller screens this creates a long scanning task and mixes mutually exclusive categories. | Keep availability as a toggle; group Make and Type into separate select/chip groups; display active-filter summary and a single Clear action. | M |
| Medium | Trust; visual hierarchy | Public quote panel — `updateQuotePanel` | `cars.html:2202` | The prominent estimate is only daily rate times days; deposit, taxes, fees, insurance, and total due are deferred to Wheelbase. “Estimated” is present, but the missing price structure can still feel like a late surprise. | Show a labeled subtotal and list what is excluded immediately below it. Copy: “Rental subtotal: $320. Deposit, tax, optional coverage, and fees are shown before payment.” | M |
| Medium | Visibility of system status | Client messaging — `sendSupportMessage` | `rentmect-client-portal/src/main.jsx:1753` | The composer has no sending state, retry, or explicit delivered status. A slow request leaves the control active, allowing duplicate messages. | Disable the composer while sending, append a pending message optimistically, then mark Sent/Failed with Retry. | S |
| Medium | Motion accessibility | Portal loading and calendar focus animation | `rentmect-admin-portal/src/styles.css:1087`, `rentmect-admin-portal/src/final-overrides.css:365`; `rentmect-client-portal/src/styles.css:45` | Portals animate the loading car and calendar pulse without a `prefers-reduced-motion` alternative. The public site has a reduced-motion block, so behavior is inconsistent. | Disable nonessential animation and smooth scrolling under `prefers-reduced-motion: reduce`. | S |
| Medium | Fitts’s Law; focus visibility | Client controls | `rentmect-client-portal/src/styles.css:2558`–`:2585`, `rentmect-client-portal/src/styles.css:895` | Core buttons are forced to 36 px, nav controls to 38 px, and inputs to 38 px—below a comfortable 44 px mobile target. The client has no global `:focus-visible` rule, and `.vehicle-clear-button:focus` removes the outline. | Use a 44 px minimum interactive target on touch layouts and a consistent high-contrast focus ring for every interactive element. | M |
| Medium | Responsive readability | Admin Payments — `PaymentsTab` | `rentmect-admin-portal/src/styles.css:3469`, `rentmect-admin-portal/src/final-overrides.css:2430` | The six-column payment grid has a fixed 850 px minimum and only becomes a horizontal scroller. On phones, headers can leave the viewport while row values lose context. | Switch to labeled payment cards below the table breakpoint or use a semantic table with a sticky first column/header and explicit scroll affordance. | M |
| Medium | Predictability; maintainability | Public booking globals — `startBooking` and inline scripts | `script.js:789`, `index.html:584`, `cars.html:2093` | `startBooking` is defined three times and page load order decides which behavior runs. The same form name can save state only, navigate to fleet, or open Wheelbase. Feedback changes silently if script order changes. | Keep one namespaced booking controller in a module and pass the intended next step through configuration. | M |
| Medium | Error identification | Client profile/checkout validation — `saveProfileDetails`, `nextWizardStep` | `rentmect-client-portal/src/main.jsx:1181`, `rentmect-client-portal/src/main.jsx:2184` | Validation appears only in a global notice and does not mark fields, retain an error summary, or move focus. Users must scan the form to discover what failed. | Add inline messages with `aria-describedby`, an error summary at the top, and focus the first invalid field. Copy: “Enter the full address, including city, state, and ZIP.” | M |
| Medium | Affordance | Client sidebar toggle | `rentmect-client-portal/src/main.jsx:2456` | The navigation toggle always uses an `X` icon for both Expand and Collapse. The icon implies close even when the action is to open navigation. | Use Menu when collapsed and X/Chevron when expanded; keep the accessible label synchronized. | S |

## 5. Low-priority polish

| Severity | Concept | Page/Component | File | Problem | Recommended Fix | Effort |
|---|---|---|---|---|---|---|
| Low | Content quality | Under-25 settings — `SettingsTab` | `rentmect-admin-portal/src/main.jsx:4506` | The same percentage example is rendered twice. This makes a sensitive pricing control look unfinished. | Remove the duplicate and keep one concrete calculated example. | XS |
| Low | Consistent language | Busy labels across both portals | `rentmect-admin-portal/src/main.jsx`; `rentmect-client-portal/src/main.jsx` | Busy copy mixes three dots and a typographic ellipsis: “Saving...,” “Opening Stripe...,” “Saving…,” and “Checking…”. Capitalization also varies. | Standardize sentence case and the single ellipsis character: “Saving…”, “Opening Stripe…”, “Checking…”. | XS |
| Low | Plain language | Public/client/admin customer-facing copy | `cars.html:261`; `rentmect-client-portal/src/BookingPreviewFleet.jsx:231`; `rentmect-admin-portal/src/main.jsx:3259` | Customer/admin screens sometimes foreground vendor or implementation names (“Supabase Booking Preview,” “Supabase calendar verified,” “audit migration”). This competes with the task and weakens the product voice. | Keep vendor names only where they explain trust or a redirect. Prefer “Live availability,” “Secure identity check,” and “Activity will appear here.” | S |

## 6. Page-by-page findings

### Public home page

- The reservation form has a clear focal point and a direct “Choose Vehicle” action.
- Labels are visually present but not explicitly associated with inputs (`index.html:241`), which weakens screen-reader and click-target behavior.
- Inline `startBooking` correctly navigates to `cars.html`, but it overrides a different global implementation from `script.js`. This is a fragile dependency rather than a stable flow (M12).
- The page still establishes “Wheelbase Checkout” as the product model (`index.html:291`), while the client portal contains a separate Supabase flow (H1).
- Native alerts interrupt date validation instead of keeping the problem next to the field (`index.html:584`, `script.js:621`).

### Public cars/fleet page

- Strengths: date inputs, availability labels, visible deposit/rate, image galleries, insurance reminder, and an availability status live region.
- Unknown cards remain actionable and appear under “Available only,” which is a launch blocker (C4).
- The filter set creates unnecessary choice density (M6).
- The quote emphasizes an incomplete subtotal without a price breakdown (M7).
- The insurance reminder has a meaningful confirmation, but lacks complete dialog keyboard behavior (H16).
- The primary card actions route to Wheelbase while the footer alone exposes the client portal preview (H1).
- The file combines over 2,200 lines of markup and inline behavior with `script.js`, increasing the likelihood of visible state drift.

### Public contact, requirements, agreement, and legal pages

- Content hierarchy is generally simple and scannable.
- The same mobile-menu control is repeated without expanded-state semantics.
- Contact links are intercepted into a JavaScript dialog; when opened, focus stays wherever it was on the page.
- Repeated header/footer markup creates a consistency risk across pages; a shared static-site template would reduce divergence without changing branding.

### Client authentication

- Strengths: passwordless entry, clear code step, disabled state during authentication, and booking-hold visibility.
- Email and OTP fields depend on placeholders rather than persistent labels (H10).
- Raw authentication errors are shown directly (H9).
- `message` is visually rendered but has no live-region semantics, so email-sent and verification errors may not be announced.

### Client booking preview and checkout

- Strengths: sticky trip summary, sequential checkout sections, hold timer, explicit secure-service handoffs, and disabled payment until prerequisites complete.
- Test vehicle behavior must be excluded from production (C5).
- Contact and upload behavior is duplicated with the wizard/account portal (H17).
- Disabled agreement/payment actions need visible explanations tied to the button, not only surrounding content.
- “Completing…” is used while the payment action may be opening Stripe or completing a test path; button copy should name the actual transition.

### Client overview and guided steps

- Strengths: one recommended guided action, concise reservation summary, explicit return countdown, and progressive disclosure for return/extend/exchange.
- The hero and header both compete to start/continue the same flow when unpaid.
- Global validation notices make incomplete-step recovery harder than necessary (M13).
- The wizard is not an accessible modal (H4).
- The dynamic tab set reduces clutter, but URL-backed steps are needed for refresh/recovery/support (H2).

### Client records and agreement

- Strengths: document status, replacement path, and agreement moved out of the main page.
- Uploads do not expose progress or protect against duplicate operations (H6).
- Agreement modal lacks dialog semantics/focus handling (H4).
- Signature canvas has an `aria-label` but no keyboard-equivalent signing method. The typed legal-name input helps identity but does not replace the drawn-signature requirement.
- Rejected-document recovery copy is good; the same specificity should be used for technical upload failures.

### Client billing

- Strengths: total due is visually prominent, line items are grouped, additional charges are separate, and terms are progressively disclosed.
- Vendor/process terminology should be reduced where it does not help the renter.
- The most important unavailable states should say why directly under the button.
- Return from Stripe should have a persistent success/cancelled state in the page, not depend only on transient notice behavior.

### Client history and messages

- Empty history is clear but has no next action.
- Message send has no pending/failed feedback (M8).
- The empty conversation inserts a synthetic-looking Rent Me CT message with “Now,” which can be mistaken for an actual sent message. Render it as an empty-state instruction instead.

### Admin dashboard

- Strengths: five compact operational metrics and a focused return monitor.
- Active emergency exceptions can crash the page (C1).
- Metric cards are not navigation, so admins cannot jump from “Maintenance Due” or “Overdue” to the filtered work list.
- A data-load failure can display zeros and “No due-soon rentals,” which is indistinguishable from healthy operations (C2).

### Admin Operations Queue

- Strengths: work is grouped by intent rather than raw status.
- Every bucket renders even when empty, creating four repeated “Clear” regions.
- Buckets cap at five without a direct “View all” route, and some next actions require manual navigation (H15).
- Approve/reject/document actions need per-row busy state and a last-action confirmation (H7).

### Admin Payments

- Strengths: the earlier tab sprawl has been reduced to four intent filters plus a Type selector.
- Rows have no drill-down/action even in “Needs Attention” (H15).
- The grid is not semantically a table (H12).
- Mobile relies on an 850 px horizontal table without contextual labels (M11).
- Partial-load error is persistent, which is good, but it exposes raw source errors and lacks Retry.

### Admin Fleet Calendar

- Strengths: canonical RPC, realtime refresh, search/status filters, 28-day window controls, protected turnaround display, vehicle dropdown scroll/focus pulse, maintenance lock visibility, and direct segment editing.
- Failed refresh does not clearly mark displayed data stale (M5).
- Drag-to-paint has no keyboard equivalent on the grid (H11).
- The 28-column grid is information-dense; add a compact week view for day-to-day operations while retaining the 28-day planning view.
- Color is paired with labels in the legend/segments, which is good. Custom colors should still be contrast-checked against text.

### Admin New Booking

- Strengths: numbered grouping, customer search, precise availability reasons, price/deposit/tax summary, disabled unavailable vehicles, and clear onboarding/payment choices.
- The flow is long but appropriately progressive; optional saved records are already collapsed.
- Global error notices should be replaced with section/field errors and focus movement.
- After creation, the route should land on a dedicated rental workspace rather than filtering the entire rental list in memory.

### Admin Rentals

- Strengths: rich procedure checklist, mileage enforcement, document review, deposit and charge handling, return workflow, and audited emergency override.
- `RentalRow` is overloaded and visually flattens too many domains (H14).
- Native and custom confirmation experiences are inconsistent (H8).
- Individual operations need row/action busy state (H7).
- The default “Needs Action” filter is appropriate, but filters should show counts and be URL-backed.

### Admin Customers and Communications

- Strengths: customer risk summary, profile/rental/documents context, channel readiness, template preview, and destination confirmation.
- Customer details/contact dialogs lack a shared focus lifecycle (H5).
- The inbox derives threads from customers with rentals. If a customer can message before a rental exists, that conversation has no route into the inbox.
- Template editor controls include placeholder-only fields, and a test-recipient input appears without a visible label (H10).

### Admin Vehicles and Maintenance

- Strengths: searchable fleet list, explicit publish state, system-controlled maintenance state, photo optimization, and milestone command center.
- The clickable vehicle row contains nested selects and buttons inside a `role=button` container (`rentmect-admin-portal/src/main.jsx:3704`), creating conflicting keyboard semantics. Make the summary itself a real button/link and keep controls as siblings.
- Status and publish mutations have no per-vehicle busy/rollback presentation (H7).
- The edit form still uses placeholder-only fields while the add form uses visible labels; these two modes should share the same field components.

### Admin Audit Log and Settings

- Audit search/filtering and expandable structured details are strong.
- Empty audit copy references installing a migration instead of giving an operational explanation (L3).
- Settings correctly reduces a long page to three groups, but the tab semantics are incomplete (M3).
- Discount and fee forms rely on placeholder labels (H10).
- The duplicated under-25 helper sentence is visible polish debt (L1).

## 7. Shared-component findings

### Component architecture

- `rentmect-admin-portal/src/main.jsx` is 6,686 lines and `rentmect-client-portal/src/main.jsx` is 5,075+ lines. Page logic, data access, domain rules, and visual primitives live together. This makes consistent feedback harder because each handler invents its own busy/error/success behavior.
- `Panel`, `Metric`, `Notice`, badges, upload cards, and modal-like structures exist, but there is no shared Button, Field, FormError, AsyncAction, EmptyState, Table, Tabs, or Dialog contract.
- The client renders the same booking step model in three places. Extracting behavior first will prevent a visual cleanup from creating three new versions.
- The public site redefines global behavior in inline scripts. A single module should own booking state, validation, and handoff.

### Recommended shared primitives

1. `AsyncButton`: idle, pending, success, error; prevents duplicate activation.
2. `Field`: visible label, hint, required/optional marker, inline error, `aria-describedby`.
3. `StatusMessage`: persistent inline error/warning and queued live-region toast for transient success.
4. `Dialog`: accessible name, focus trap, Escape/backdrop policy, scroll lock, focus restoration.
5. `EmptyState`: first-use, zero-results, and error variants with appropriate action.
6. `DataTable` / `DataCardList`: semantic desktop table and labeled mobile representation.
7. `Tabs` and `FilterGroup`: correct keyboard/ARIA semantics and URL synchronization.
8. `PageState`: loading, degraded, stale, ready, and fatal error handling.
9. `BookingStep`: one behavioral model reused by guest preview, guided flow, and signed-in portal.
10. `RentalTaskLink`: opens the exact rental/action and preserves origin.

## 8. Accessibility findings

### Must fix

- Add reliable names and visible labels to placeholder-only controls.
- Add an accessible modal primitive and migrate all high-value dialogs.
- Add live-region semantics for authentication, notices, upload results, and availability changes.
- Make calendar creation/editing keyboard-equivalent.
- Remove the nested interactive structure from vehicle list rows.
- Use semantic tables where column relationships matter.
- Add global client/public focus-visible styles and never suppress focus without replacement.
- Raise mobile touch targets to at least 44 by 44 CSS pixels.

### Should fix

- Add `aria-current` to portal navigation.
- Complete the WAI-ARIA tabs pattern in Settings; use `aria-pressed` for non-tab filter toggles.
- Expose progress as an ordered list with text states and `aria-current=step`.
- Add `prefers-reduced-motion` handling to both portals.
- Make mobile menu expanded state programmatically available.
- Restore focus after every modal closes.
- Add a keyboard alternative to the signature canvas, subject to legal/product approval.
- Ensure custom availability colors are checked for text and non-text contrast.

### Responsive observations

- Client button/input sizing was intentionally compressed to 36–38 px in `rentmect-client-portal/src/styles.css:2482`; this should not apply on touch layouts.
- Admin Payments uses a fixed 850 px row and horizontal overflow. A labeled card mode is more usable on phones.
- Admin calendar necessarily scrolls horizontally, but selected date, vehicle, and legend should remain sticky and keyboard reachable.
- Public fleet filters and long card grids adapt to one column, but the filter choice count remains high.
- Admin’s floating mobile navigation can be dragged and stored, which is flexible, but it needs safe-area bounds, a reset position option, and a non-drag keyboard path.

## 9. Recommended design-system rules

### Foundations

- One token source per product, with a small shared brand layer: canvas, surface, text, muted text, border, success, warning, danger, info, focus, spacing, radii, shadows, type scale, and motion.
- Do not redefine the same semantic token later in the cascade. Theme changes should occur through one scoped theme selector, not repeated `:root` blocks.
- Use a 4 px base spacing grid with named steps: 4, 8, 12, 16, 24, 32, 48.
- Use three surface levels only: page canvas, section panel, elevated dialog/popover.

### Typography and hierarchy

- One page title, one section-title scale, one card-title scale, and one metadata scale.
- Eyebrows are optional orientation labels, not required above every panel.
- Operational pages should lead with the next action or exception, then totals, then history.
- Money, dates, mileage, and status should use tabular numerals and consistent formatting.

### Actions

- One primary action per panel/dialog.
- Secondary actions are neutral; destructive actions use danger styling and explicit consequence copy.
- Icon-only buttons require an accessible name and at least a 44 px touch target.
- Every async action must define pending, success, error, retry, and duplicate-click behavior.
- Disabled actions must have a nearby explanation; prefer preventing invalid states earlier.

### Forms

- Visible label for every input. Placeholder is an example, never the label.
- Required/optional state is explicit and consistent.
- Validate after interaction and on submit; preserve data; focus the first error.
- Errors are specific, local, and recovery-oriented. Never expose database policy/schema wording.
- Long workflows use numbered groups and a persistent summary; optional material is collapsed.

### Feedback

- Loading: skeleton for page data, local spinner for mutations.
- Success: transient live-region toast plus persistent changed state.
- Error: persistent inline message with Retry or next step.
- Empty: state-specific explanation plus a useful action.
- Stale: retain last good data, label its age, and expose refresh.
- Destructive: custom confirmation with target, consequence, and reversal policy.

### Tables and lists

- Use tables for values compared by column; use cards for heterogeneous tasks.
- Desktop tables have semantic headers, meaningful default sort, and row actions.
- Mobile tables become labeled cards unless horizontal comparison is the primary task.
- Filters show counts and active state, preserve state in the URL, and include Clear.

### Modals

- Use dialogs only for focused, interruptive tasks; prefer routes for large workspaces.
- Trap focus, support Escape when safe, restore focus, lock background scroll, and set the background inert.
- Do not close destructive or in-progress dialogs from accidental backdrop clicks.

### Motion

- Motion must explain state change, not decorate routine operations.
- Respect reduced-motion preferences.
- Keep feedback transitions under 200 ms; avoid continuous animation outside a genuinely active wait.

## 10. Implementation roadmap

### Phase 1 — Broken or confusing feedback

Goal: make displayed state trustworthy before visual refactoring.

1. Fix the `Dashboard` emergency-exception crash and add route-level error boundaries.
2. Introduce explicit required/degraded resource states in both portal loaders.
3. Make unknown public availability non-bookable and correct “Available only.”
4. remove or production-gate the client test vehicle/test payment lane.
5. Decide and enforce one production booking funnel.
6. Replace raw customer-facing infrastructure errors with mapped recovery copy and internal logging.
7. Add per-action busy protection to uploads, status changes, approvals, messages, publishing, and payment actions.
8. Replace high-risk native confirmations with one explicit confirmation pattern.
9. Add persistent Stripe success/cancelled and calendar stale/retry states.

Exit criteria:

- No failed resource can render as a healthy empty state.
- No unknown inventory can be booked.
- No test booking path is reachable in production without authorization.
- Every critical mutation has pending, success, error, and retry behavior.

### Phase 2 — Visual hierarchy and consistency

Goal: reduce cognitive load and establish predictable interaction patterns.

1. Extract one token foundation and remove obsolete theme/override passes.
2. Create Button, Field, StatusMessage, EmptyState, DataTable/DataCardList, Tabs, and Dialog primitives.
3. Refactor `RentalRow` into a compact task summary plus dedicated rental workspace.
4. Add direct task links from Dashboard, Queue, Payments, and maintenance metrics.
5. Consolidate client booking step components across preview, wizard, and account views.
6. Simplify public fleet filters and clarify subtotal versus total-due hierarchy.
7. Standardize terminology, ellipses, capitalization, status labels, and vendor disclosure.

Exit criteria:

- One clear primary action per operational region.
- One component owns each common interaction pattern.
- Admins can move from alert to resolution without searching a second page.

### Phase 3 — Accessibility and responsive behavior

Goal: make all critical workflows operable with keyboard, screen reader, and touch.

1. Migrate all dialogs to the accessible primitive.
2. Label every control and implement field-level errors.
3. Add live regions, navigation/current-step semantics, and semantic tables.
4. Provide keyboard equivalents for calendar painting and signature completion.
5. Add global focus-visible styles and 44 px touch targets.
6. Implement mobile card layouts for Payments and other comparison tables.
7. Add reduced-motion support and verify custom color contrast.
8. Test at 320, 375, 768, 1024, and 1440 px with keyboard-only and screen-reader passes.

Exit criteria:

- Critical flows meet WCAG 2.2 AA interaction expectations.
- No critical action requires a mouse or precision target.
- Mobile tables preserve labels and actions without hidden context.

### Phase 4 — Microinteractions and polish

Goal: improve speed, confidence, and perceived quality after correctness is stable.

1. Add shell-preserving skeletons, last-updated timestamps, and subtle local success states.
2. Add upload progress, retry, and completion summaries.
3. Add filter counts, clear actions, and route-state restoration.
4. Normalize copy and remove internal/vendor jargon where it does not help.
5. Add carefully limited row highlight/focus transitions with reduced-motion alternatives.
6. Add visual regression coverage for the canonical design tokens and shared components.

Exit criteria:

- Feedback is timely without being noisy.
- Users retain context through refresh, redirect, and navigation.
- The visual system can be changed without another override layer.

### Questions to resolve before implementation

1. Is Wheelbase still the intended production checkout, or should every public booking enter the Supabase/client-portal flow?
2. Should the `?preview=fleet` route exist in production at all, and who is allowed to use test bookings?
3. Which resources are required to render each portal page, and which may be shown as degraded/stale?
4. Should admins be able to deep-link directly to a rental, customer, payment, maintenance task, or calendar vehicle?
5. What file size/type limits should clients see before uploading license and insurance documents?
6. Does legal policy require a drawn signature, or can typed signature plus explicit consent serve as the keyboard-accessible alternative?
7. Which actions require owner-only permission or stronger confirmation: refunds, external payment, cancellation, maintenance override, customer block, and vehicle deletion?
8. What mobile devices and browsers are part of launch acceptance?
