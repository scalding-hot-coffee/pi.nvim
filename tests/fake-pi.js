#!/usr/bin/env node
const fs = require("node:fs");
const readline = require("node:readline");

if (process.env.PI_QUICK_EDIT_TEST_LOG) {
  fs.writeFileSync(process.env.PI_QUICK_EDIT_TEST_LOG, JSON.stringify({
    argv: process.argv.slice(2),
    profileName: process.env.PI_PROFILE_NAME,
    profileModel: process.env.PI_PROFILE_MODEL,
    profileThinking: process.env.PI_PROFILE_THINKING,
  }));
}

const send = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
const input = readline.createInterface({ input: process.stdin });
input.on("line", (line) => {
  const request = JSON.parse(line);
  if (request.type !== "prompt") return;
  const delayed = request.message.includes("DELAY_TEST");
  const replacement = delayed ? "remote" : "new";
  const text = JSON.stringify({ replacement_text: replacement });
  send({ id: request.id, type: "response", command: "prompt", success: true });
  const respond = () => {
    send({ type: "message_start", message: { role: "assistant" } });
    send({
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: text },
    });
    send({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text }] } });
    send({ type: "agent_end", messages: [] });
    send({ type: "agent_settled" });
  };
  if (delayed) setTimeout(respond, 150);
  else respond();
});
