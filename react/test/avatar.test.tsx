// A person's picture: the host's avatar_url with the email's SHA-256; no picture on record → the initials.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { Avatar } from "../src";
import { KanbanHostProvider, type KanbanHostValue } from "../src/host";
import { resetAvatars, sha256Hex } from "../src/lib/avatar";

const host = (avatar_url: string | null, me = "op@example.com") =>
  ({ me, config: { avatar_url } }) as unknown as KanbanHostValue;
const show = (avatar_url: string | null, email: string, me?: string) =>
  render(
    <KanbanHostProvider value={host(avatar_url, me)}>
      <Avatar name="Ann Lee" email={email} />
    </KanbanHostProvider>,
  );
const TEMPLATE = "https://pics.test/avatar/{sha256}?s=80&d=404";

afterEach(resetAvatars);

describe("a person's avatar", () => {
  it("is the template with the SHA-256 of the trimmed, lower-cased email", async () => {
    // the SHA-256 of "ann@example.com" (computed independently)
    expect(await sha256Hex("ann@example.com")).toBe("71d4f55f72fa128dfb468a1a3901507c804b74316488744d769d7f4b16696476");
    show(TEMPLATE, "  Ann@Example.COM ");
    const img = await screen.findByRole("img", { name: "Ann Lee" });
    expect(img).toHaveAttribute("src", `https://pics.test/avatar/${await sha256Hex("ann@example.com")}?s=80&d=404`);
    expect(img).toHaveClass("avatar");
  });

  it("no picture on record (the image fails) → the initials, and the address is not asked again", async () => {
    const first = show(TEMPLATE, "ann@example.com");
    fireEvent.error(await screen.findByRole("img", { name: "Ann Lee" }));
    await waitFor(() => expect(first.container.querySelector("span.avatar")).toHaveTextContent("AL"));
    first.unmount();
    const again = show(TEMPLATE, "ann@example.com");
    await new Promise((r) => setTimeout(r, 20));
    expect(again.container.querySelector("img")).toBeNull();
    expect(again.container.querySelector("span.avatar")).toHaveTextContent("AL");
  });

  it("no template → the initials, no request; an agent never gets a picture", async () => {
    const { container } = show(null, "ann@example.com");
    await new Promise((r) => setTimeout(r, 20));
    expect(container.querySelector("img")).toBeNull();
    expect(container.querySelector("span.avatar")).toHaveTextContent("AL");
    const agent = show(TEMPLATE, "worker-1");
    await new Promise((r) => setTimeout(r, 20));
    expect(agent.container.querySelector("img")).toBeNull();
    expect(agent.container.querySelector("svg.ak-face")).not.toBeNull();
  });
});
