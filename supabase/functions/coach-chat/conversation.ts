// The pure part of the coach chat: turning the saved conversation into turns
// for Claude, and reading Claude's content when a reply fell back to another
// model partway. No I/O, so it's covered by `conversation.test.ts`.

import type Anthropic from "npm:@anthropic-ai/sdk@1.3.0";

type MessageParam = Anthropic.Beta.Messages.BetaMessageParam;
type ContentBlock = Anthropic.Beta.Messages.BetaContentBlock;

/** A row of `coach_messages`, with the columns the chat reads. */
export type MessageRow = {
  id: string;
  role: "user" | "assistant";
  content: string;
  status: "generating" | "ready" | "failed";
  record_id: string | null;
  review_id: string | null;
};

/** The conversation for Claude: alternating turns starting with the runner,
 * the latest message led by the app's context. Messages that aren't ready
 * (failed replies) are left out, and each reply that suggested a change is
 * followed by its note from `notes`, by review id. Throws if the conversation
 * doesn't end with a message from the runner. */
export function conversation(history: MessageRow[], notes: Map<string, string>, context: string): MessageParam[] {
  const turns: { role: "user" | "assistant"; text: string }[] = [];
  for (const row of history) {
    if (row.status !== "ready") continue;
    const note = row.review_id ? notes.get(row.review_id) : undefined;
    const text = [row.content.trim(), note].filter(Boolean).join("\n\n");
    if (!text) continue;
    const last = turns.at(-1);
    if (last?.role === row.role) {
      last.text += `\n\n${text}`;
    } else {
      turns.push({ role: row.role, text });
    }
  }
  while (turns[0]?.role === "assistant") turns.shift();
  if (turns.at(-1)?.role !== "user") throw new Error("There's no message to answer.");

  return turns.map((turn, index): MessageParam => {
    if (index < turns.length - 1) return { role: turn.role, content: turn.text };
    return {
      role: "user",
      content: [
        { type: "text", text: `<context>\n${context}\n</context>` },
        { type: "text", text: turn.text, cache_control: { type: "ephemeral" } },
      ],
    };
  });
}

/** The blocks after a mid-output fallback (all of them without one): only
 * those are the model's final word, so only their tool calls run. */
export function afterFallback(content: ContentBlock[]) {
  const boundary = content.findLastIndex((block) => block.type === "fallback");
  return content.slice(boundary + 1);
}

/** The assistant turn as it goes back to Claude: before a fallback, only text
 * is kept (the fallback marker itself is only for the record). */
export function echoable(content: ContentBlock[]): ContentBlock[] {
  const boundary = content.findLastIndex((block) => block.type === "fallback");
  return content.filter((block, index) => index > boundary || block.type === "text");
}

/** The reply's text; a fallback continues the declined model's text, so it all reads on. */
export function textOf(content: ContentBlock[]) {
  return content
    .filter((block): block is Anthropic.Beta.Messages.BetaTextBlock => block.type === "text")
    .map((block) => block.text)
    .join("");
}

/** Two stretches of a reply, a paragraph apart. */
export function joinText(earlier: string, more: string) {
  return [earlier.trim(), more.trim()].filter(Boolean).join("\n\n");
}
