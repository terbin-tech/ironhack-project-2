// Connects to result's Socket.IO endpoint with Node's built-in WebSocket
// client and waits for a "scores" event whose count for b equals the expected
// value. It speaks the two protocol layers directly, so no client package is
// installed: Engine.IO frames ("0" open, "2" ping, "3" pong, "4" message) carry
// Socket.IO packets ("0" connect, "2" event).
// Usage: node scores.mjs <websocket url> <expected count for b>
const [url, expected] = process.argv.slice(2);

const fail = (message) => {
  console.error(`FAIL: ${message}`);
  process.exit(1);
};
const timer = setTimeout(() => fail(`no scores event with b = ${expected} within 15 s`), 15000);

const ws = new WebSocket(url);
ws.onerror = (event) => fail(`WebSocket error: ${event.message ?? "unknown"}`);
ws.onmessage = ({ data }) => {
  if (data === "2") return ws.send("3");
  if (data.startsWith("0")) return ws.send("40");
  if (!data.startsWith("42")) return;
  const [name, json] = JSON.parse(data.slice(2));
  if (name !== "scores") return;
  if (String(JSON.parse(json).b ?? 0) === expected) {
    clearTimeout(timer);
    process.exit(0);
  }
};
