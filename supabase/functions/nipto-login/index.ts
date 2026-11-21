// Legacy email-backed login endpoint. Kept only so deployments can retire
// the old route explicitly during the Nipto-native authentication cutover.
// New clients must use the Nipto identity issuer.
Deno.serve((_request: Request) => {
  return new Response(
    JSON.stringify({
      error: "This legacy sign-in endpoint has been retired. Update Nipto to use Nipto ID authentication.",
    }),
    {
      status: 410,
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
      },
    },
  );
});
