// Renders the looping og:video card: the island scene as the Mac's wallpaper,
// Git Island opening and closing at the top. Every frame is stepped through
// ?capture, so reruns match. Needs Google Chrome and ffmpeg with libx264.
// From website/: npm run capture:video [-- public/social-video-vN.mp4]
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { chromium } from "playwright-core";
import { createServer } from "vite";

const output = process.argv[2] ?? "public/social-video-v1.mp4";
// Same size as og:image so the card keeps its shape when the video plays.
const fps = 30,
  loop = 6,
  fade = 0.5,
  width = 1200,
  height = 630;
// Low over the water: the tree-covered hill, the sailboat in front.
const view = { position: [0.5, 1.3, 10], look: [2.5, 1.2, 3] };
// What happens on the island, in seconds.
const beats = [
  [1.0, (capture) => capture.open(true)],
  [2.4, (capture) => capture.status(19, "ready", "Checks passed")],
  [4.6, (capture) => capture.open(false)],
];

const frames = await mkdtemp(path.join(tmpdir(), "git-island-clip-"));
const server = await createServer({
  server: { host: "127.0.0.1", port: 5190 },
  logLevel: "error",
});
const browser = await chromium.launch({ channel: "chrome" });
try {
  await server.listen();
  const page = await browser.newPage({
    viewport: { width, height },
    deviceScaleFactor: 2,
    reducedMotion: "no-preference",
  });
  await page.goto(server.resolvedUrls.local[0] + "?capture");
  await page.evaluate(() => window.capture.ready);
  if ((await page.evaluate(() => document.body.dataset.seaModels)) !== "2")
    throw new Error("The scene did not load; is WebGL available?");
  // Let the load-time canvas fade finish before the capture clock starts.
  await page.waitForTimeout(600);
  // Sea time 7 keeps the whale under for the whole clip. The sailboat is
  // anchored right of the island (its course at sea time 10), so the last
  // frame dissolves into the first without a second boat.
  await page.evaluate(
    (view) => window.capture.start({ seaTime: 7, anchor: 10, view }),
    view,
  );
  const count = Math.round((loop + fade) * fps);
  let next = 0;
  for (let i = 0; i < count; i++) {
    const s = i / fps;
    while (next < beats.length && beats[next][0] <= s)
      await page.evaluate(`(${beats[next++][1]})(window.capture)`);
    await page.evaluate((s) => window.capture.frame(s), s);
    await page.screenshot({
      path: path.join(frames, `${String(i).padStart(4, "0")}.png`),
    });
  }
  // Dissolve the tail into the opening so the clip loops without a cut.
  const head = Math.round(fade * fps);
  await new Promise((resolve, reject) =>
    spawn(
      "ffmpeg",
      [
        "-y",
        "-loglevel", "error",
        "-framerate", String(fps),
        "-i", path.join(frames, "%04d.png"),
        "-filter_complex",
        `[0]scale=${width}:${height}:flags=lanczos,split[a][b];` +
          `[a]trim=start_frame=${head},setpts=PTS-STARTPTS[body];` +
          `[b]trim=end_frame=${head},setpts=PTS-STARTPTS[head];` +
          `[body][head]xfade=transition=fade:duration=${fade}:offset=${loop - fade},format=yuv420p`,
        "-c:v", "libx264",
        "-preset", "slow",
        "-crf", "20",
        "-movflags", "+faststart",
        "-an",
        output,
      ],
      { stdio: "inherit" },
    ).on("exit", (code) =>
      code === 0 ? resolve() : reject(new Error("ffmpeg exited " + code)),
    ),
  );
  console.log("Wrote", output);
} finally {
  await browser.close();
  await server.close();
  await rm(frames, { recursive: true, force: true });
}
