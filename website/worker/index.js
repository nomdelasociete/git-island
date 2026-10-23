// Static assets answer Range requests with the whole file, and Apple's video
// stack (iMessage link previews, Safari) refuses to play an MP4 served that
// way. cloudflare.config.ts routes the og:video file here first; every other
// path only reaches this Worker when no asset matches, and gets the same 404.
export default {
  async fetch(request, env) {
    const asset = await env.ASSETS.fetch(new URL(request.url));
    if (!asset.ok) return asset;
    const body = await asset.arrayBuffer(),
      size = body.byteLength,
      headers = new Headers(asset.headers);
    headers.set("accept-ranges", "bytes");
    headers.delete("content-length");
    const head = request.method === "HEAD";
    const range = /^bytes=(\d*)-(\d*)$/.exec(request.headers.get("range") ?? "");
    // Range only applies to GET, and an If-Range that is not this asset's
    // strong ETag asks for the whole file (RFC 9110). Assets send no
    // Last-Modified, so a date never matches.
    const ifRange = request.headers.get("if-range"),
      etag = asset.headers.get("etag");
    const current = !ifRange || (etag && !etag.startsWith("W/") && ifRange === etag);
    if (head || !current || !range || (!range[1] && !range[2]))
      return new Response(head ? null : body, { headers });
    // "bytes=a-b", "bytes=a-" or the last n bytes with "bytes=-n".
    const start = range[1] ? Number(range[1]) : Math.max(0, size - Number(range[2])),
      end = range[1] && range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
    if (start > end) {
      headers.set("content-range", `bytes */${size}`);
      return new Response(null, { status: 416, headers });
    }
    headers.set("content-range", `bytes ${start}-${end}/${size}`);
    return new Response(head ? null : body.slice(start, end + 1), {
      status: 206,
      headers,
    });
  },
};
