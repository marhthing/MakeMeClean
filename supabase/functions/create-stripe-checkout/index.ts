import Stripe from "npm:stripe@16.12.0";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, x-client-info, apikey",
};

const json = (status: number, data: unknown) =>
  new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json", ...corsHeaders } });

function normalizeOrigin(value: string | null | undefined) {
  return (value ?? "").trim().replace(/\/$/, "");
}

function withoutWww(origin: string) {
  return origin.replace("://www.", "://");
}

function sameSiteOrigin(a: string, b: string) {
  return a === b || withoutWww(a) === withoutWww(b);
}

function getSlotStart(timeSlot: string | null | undefined) {
  return timeSlot?.match(/\b(\d{2}:\d{2})\b/)?.[1] ?? null;
}

function isPayableBooking(date: string, status: string | null | undefined) {
  if (status === "cancelled") return false;
  const nowParts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/London",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date());

  const part = (type: string) => nowParts.find((p) => p.type === type)?.value ?? "";
  const today = `${part("year")}-${part("month")}-${part("day")}`;

  return date >= today;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json(405, { ok: false, error: "Method not allowed" });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");

    if (!supabaseUrl || !serviceKey || !stripeKey) {
      return json(500, { ok: false, error: "Server misconfiguration" });
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!token) return json(401, { ok: false, error: "Unauthorised" });

    const { bookingId, origin } = (await req.json()) as { bookingId?: string; origin?: string };
    if (!bookingId) return json(400, { ok: false, error: "bookingId is required" });

    const configuredOrigin = normalizeOrigin(Deno.env.get("SITE_URL"));
    const requestOrigin = normalizeOrigin(req.headers.get("Origin"));
    const clientOrigin = normalizeOrigin(origin);

    if (configuredOrigin) {
      if (
        (requestOrigin && !sameSiteOrigin(requestOrigin, configuredOrigin)) ||
        (clientOrigin && !sameSiteOrigin(clientOrigin, configuredOrigin))
      ) {
        return json(403, { ok: false, error: "Invalid origin" });
      }
    }

    const appOrigin = configuredOrigin || requestOrigin || clientOrigin;
    if (!appOrigin) return json(400, { ok: false, error: "Missing site origin" });

    const supabase = createClient(supabaseUrl, serviceKey);
    const stripe = new Stripe(stripeKey, { apiVersion: "2024-06-20" });

    const { data: userData, error: userErr } = await supabase.auth.getUser(token);
    if (userErr || !userData?.user) return json(401, { ok: false, error: "Unauthorised" });

    const { data: booking, error: bookingErr } = await supabase
      .from("bookings")
      .select("id, user_id, service_name, date, time_slot, price, invoice_number, payment_status")
      .eq("id", bookingId)
      .single();

    if (bookingErr || !booking) return json(404, { ok: false, error: "Booking not found" });
    if (booking.user_id !== userData.user.id) return json(403, { ok: false, error: "Forbidden" });
    if (booking.payment_status === "paid") {
      return json(409, { ok: false, error: "This booking is already paid" });
    }
    if (!isPayableBooking(String(booking.date), booking.status)) {
      return json(409, { ok: false, error: "This booking date has already passed or is cancelled" });
    }

    const amount = Math.round(Number(booking.price) * 100);
    if (!Number.isFinite(amount) || amount <= 0) {
      return json(400, { ok: false, error: "Invalid booking amount" });
    }

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      client_reference_id: booking.id,
      customer_email: userData.user.email ?? undefined,
      line_items: [
        {
          quantity: 1,
          price_data: {
            currency: "gbp",
            unit_amount: amount,
            product_data: {
              name: `MakeMeClean - ${booking.service_name}`,
              description: `${booking.date} - ${booking.time_slot}`,
            },
          },
        },
      ],
      payment_intent_data: {
        metadata: {
          booking_id: booking.id,
          user_id: userData.user.id,
          invoice_number: booking.invoice_number ?? booking.id,
        },
      },
      metadata: {
        booking_id: booking.id,
        user_id: userData.user.id,
        invoice_number: booking.invoice_number ?? booking.id,
      },
      success_url: `${appOrigin}/pay/${booking.id}?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${appOrigin}/bookings/${booking.id}`,
    });

    if (!session.url) {
      return json(500, { ok: false, error: "Stripe did not return a checkout URL" });
    }

    return json(200, { ok: true, url: session.url, sessionId: session.id });
  } catch (e) {
    console.error("[create-stripe-checkout]", e);
    return json(500, { ok: false, error: String((e as Error)?.message ?? e) });
  }
});
