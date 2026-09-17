import { assertEquals } from "jsr:@std/assert@1";
import {
  markdownToSlack,
  markdownToWhatsApp,
  slackToMarkdown,
  whatsappToMarkdown,
} from "./markdown.ts";

Deno.test("whatsappToMarkdown: *bold* and ~strike~ become CommonMark", () => {
  assertEquals(whatsappToMarkdown("hola *mundo*"), "hola **mundo**");
  assertEquals(whatsappToMarkdown("~no~ sí"), "~~no~~ sí");
});

Deno.test("whatsappToMarkdown: arithmetic and filenames are literal", () => {
  assertEquals(whatsappToMarkdown("2*3 = 6 y 2 * 3"), "2*3 = 6 y 2 * 3");
  assertEquals(whatsappToMarkdown("ver a_b.pdf"), "ver a_b.pdf");
});

Deno.test("whatsappToMarkdown: code spans pass through untouched", () => {
  assertEquals(whatsappToMarkdown("`*x*` y ```*y*```"), "`*x*` y ```*y*```");
});

Deno.test("markdownToWhatsApp: **bold**, *italic*, headers, ~~strike~~", () => {
  assertEquals(markdownToWhatsApp("**b** *i* ~~s~~"), "*b* _i_ ~s~");
  assertEquals(markdownToWhatsApp("# Título\ntexto"), "*Título*\ntexto");
});

Deno.test("markdownToWhatsApp ∘ whatsappToMarkdown is stable on emphasis", () => {
  const wa = "hola *mundo* y ~chau~";
  assertEquals(markdownToWhatsApp(whatsappToMarkdown(wa)), wa);
});

Deno.test("markdownToSlack: escapes entities and rewrites links", () => {
  assertEquals(
    markdownToSlack("a < b & [doc](https://x.test/a?b=1&c=2)"),
    "a &lt; b &amp; <https://x.test/a?b=1&amp;c=2|doc>",
  );
});

Deno.test("markdownToSlack: leading blockquote survives escaping", () => {
  assertEquals(markdownToSlack("> cita"), "> cita");
});

Deno.test("slackToMarkdown: links, mentions, entities", () => {
  assertEquals(
    slackToMarkdown("<https://x.test|doc> en <#C1|general> <!here> &amp; *b*"),
    "[doc](https://x.test) en #general @here & **b**",
  );
});
