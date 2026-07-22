# Tomorrow: Fix Booking Preview Email Codes

Goal: connect Supabase Auth to Twilio SendGrid so new and returning customers receive a numeric email code instead of a confirmation link.

## 1. Create or open SendGrid

- [ ] Open the Twilio SendGrid dashboard.
- [ ] Start the free Email API trial if necessary.
- [ ] Confirm the trial allows 100 emails per day for 60 days.

## 2. Verify a sender

- [ ] Go to **Settings → Sender Authentication**.
- [ ] Under **Single Sender Verification**, click **Verify a Single Sender**.
- [ ] Use an email address that can receive the verification message.
- [ ] Complete all required business/contact fields.
- [ ] Open the verification email and approve the sender.
- [ ] Confirm SendGrid shows the sender as verified.

The sender address entered in Supabase must exactly match this verified address.

## 3. Create the SendGrid key

- [ ] Go to **Settings → API Keys**.
- [ ] Click **Create API Key**.
- [ ] Name it `Supabase Auth`.
- [ ] Choose **Restricted Access**.
- [ ] Give **Mail Send** full access and leave unrelated permissions disabled.
- [ ] Create and privately copy the key.

Do not place the key in this file, source control, screenshots, or chat.

## 4. Connect SendGrid to Supabase

- [ ] Open **Supabase → Authentication → Emails → SMTP Settings**.
- [ ] Turn **Enable Custom SMTP** on.
- [ ] Enter the following:

```text
Sender name: Rent Me CT
Sender email: [exact SendGrid-verified email]
Host: smtp.sendgrid.net
Port: 587
Username: apikey
Password: [SendGrid API key]
```

- [ ] Save the SMTP settings.

The username is literally `apikey`. Do not use the Twilio Account SID, Twilio Auth Token, or normal SendGrid login password.

## 5. Confirm both Supabase templates

- [ ] Open **Authentication → Emails → Confirm signup**.
- [ ] Remove any `{{ .ConfirmationURL }}` link.
- [ ] Make sure the body contains `{{ .Token }}`.
- [ ] Open **Authentication → Emails → Magic link or OTP**.
- [ ] Remove any `{{ .ConfirmationURL }}` link.
- [ ] Make sure the body contains `{{ .Token }}`.

Suggested body for both templates:

```html
<h2>Your Rent Me CT verification code</h2>
<p>Enter this code to continue your booking:</p>
<h1 style="font-size:32px;letter-spacing:6px;">{{ .Token }}</h1>
<p>This code expires shortly.</p>
```

## 6. Adjust Supabase limits

- [ ] Open **Authentication → Rate Limits**.
- [ ] Set email sends to `100` per hour.
- [ ] Set OTP requests to `100` per hour.
- [ ] Set the minimum interval between email requests to `30` seconds.
- [ ] Save the changes.

Do not repeatedly click the send-code button. Wait at least 30 seconds between requests.

## 7. Test Booking Preview

- [ ] Wait 30–60 seconds after saving SMTP settings.
- [ ] Open Booking Preview with selected pickup and return dates.
- [ ] Confirm the test-vehicle details page appears first.
- [ ] Continue to checkout.
- [ ] Test with a brand-new email address.
- [ ] Confirm the message comes from the SendGrid-verified sender, not `mail.app.supabase.io`.
- [ ] Confirm the email contains a numeric code instead of a confirmation link.
- [ ] Enter the code and confirm checkout opens.
- [ ] Test an existing customer email and confirm it also receives a code.
- [ ] Check **SendGrid → Email Activity** if delivery fails.
- [ ] Check **Supabase → Authentication → Logs** if Supabase rejects the request.

## Do not change

- `cars.html`
- `index.html`
- `supabase/functions/wheelbase-availability/index.ts`
- The public Wheelbase availability or reservation flow

The custom flow must remain isolated behind Booking Preview until its complete test passes.
