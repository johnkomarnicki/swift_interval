import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import type Anthropic from "npm:@anthropic-ai/sdk@1.3.0";
import { afterFallback, conversation, echoable, joinText, type MessageRow, textOf } from "./conversation.ts";

type ContentBlock = Anthropic.Beta.Messages.BetaContentBlock;

let nextId = 0;
function row(role: MessageRow["role"], content: string, extra: Partial<MessageRow> = {}): MessageRow {
  return { id: `m${nextId++}`, role, content, status: "ready", record_id: null, review_id: null, ...extra };
}

Deno.test("conversation puts the context in front of the latest message only", () => {
  const messages = conversation(
    [row("user", "How was my run?"), row("assistant", "Strong finish."), row("user", "  And this week?  ")],
    new Map(),
    "Today is 2026-11-01 (sun).",
  );
  assertEquals(messages.length, 3);
  assertEquals(messages[0], { role: "user", content: "How was my run?" });
  assertEquals(messages[1], { role: "assistant", content: "Strong finish." });
  assertEquals(messages[2], {
    role: "user",
    content: [
      { type: "text", text: "<context>\nToday is 2026-11-01 (sun).\n</context>" },
      { type: "text", text: "And this week?", cache_control: { type: "ephemeral" } },
    ],
  });
});

Deno.test("conversation leaves out failed replies and joins the runner's messages around them", () => {
  const messages = conversation(
    [
      row("user", "Can I skip Tuesday?"),
      row("assistant", "", { status: "failed" }),
      row("user", "Hello?"),
    ],
    new Map(),
    "ctx",
  );
  assertEquals(messages.length, 1);
  assertEquals(messages[0].role, "user");
  assertEquals((messages[0].content as { text: string }[])[1].text, "Can I skip Tuesday?\n\nHello?");
});

Deno.test("conversation starts with the runner when the history was cut mid-exchange", () => {
  const messages = conversation([row("assistant", "Old reply"), row("user", "New question")], new Map(), "ctx");
  assertEquals(messages.length, 1);
  assertEquals(messages[0].role, "user");
});

Deno.test("conversation follows a reply that suggested a change with what became of it", () => {
  const messages = conversation(
    [
      row("user", "Make next week easier"),
      row("assistant", "Here's an easier week.", { review_id: "r1" }),
      row("user", "Thanks"),
    ],
    new Map([["r1", "[You suggested a plan change. They accepted it.]"]]),
    "ctx",
  );
  assertEquals(messages[1], {
    role: "assistant",
    content: "Here's an easier week.\n\n[You suggested a plan change. They accepted it.]",
  });
});

Deno.test("conversation needs a message from the runner to answer", () => {
  assertThrows(() => conversation([], new Map(), "ctx"));
  assertThrows(() => conversation([row("user", "Hi"), row("assistant", "Hello!")], new Map(), "ctx"));
});

const text = (value: string) => ({ type: "text", text: value, citations: null }) as ContentBlock;
const thinking = { type: "thinking", thinking: "", signature: "sig" } as ContentBlock;
const toolUse = (id: string) => ({ type: "tool_use", id, name: "propose_plan_change", input: {} }) as ContentBlock;
const fallback = { type: "fallback" } as unknown as ContentBlock;

Deno.test("without a fallback every block counts and goes back as it is", () => {
  const content = [thinking, text("Sure."), toolUse("a")];
  assertEquals(afterFallback(content), content);
  assertEquals(echoable(content), content);
});

Deno.test("after a mid-output fallback only the new model's tool calls run, and only text goes back from before it", () => {
  const content = [thinking, text("Let me "), toolUse("declined"), fallback, text("look at that."), toolUse("final")];
  assertEquals(afterFallback(content), [text("look at that."), toolUse("final")]);
  assertEquals(echoable(content), [text("Let me "), text("look at that."), toolUse("final")]);
  assertEquals(textOf(content), "Let me look at that.");
});

Deno.test("joinText puts stretches of a reply a paragraph apart, skipping empty ones", () => {
  assertEquals(joinText("", " First. "), "First.");
  assertEquals(joinText("First.", "Second."), "First.\n\nSecond.");
  assertEquals(joinText("First.", "  "), "First.");
});
